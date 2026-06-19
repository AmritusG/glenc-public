// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation

/// One decoded video frame's location in a DXV MOV file. The byte range
/// described here points at the *full* DXV packet (12-byte header +
/// payload). The demuxer doesn't strip the header — that happens in the
/// per-frame decoder where we also need the header's raw_flag to decide
/// whether to LZF-decompress.
public struct DXVFrameEntry {
    public let fileOffset: UInt64
    public let size: UInt32
    public let presentationTime: Double  // seconds from start
    public init(fileOffset: UInt64, size: UInt32, presentationTime: Double) {
        self.fileOffset = fileOffset
        self.size = size
        self.presentationTime = presentationTime
    }
}

/// Codec variant identified at the trak's sample description. Drives both
/// the LZF/DXT decode path and the GPU upload format chosen by the
/// renderer. Texture format only; codec generation (DXV1 vs DXV3 packet
/// shape) is carried by `DXVGeneration` on the surrounding index.
public enum DXVVariant {
    case dxt1   // DXV3 normal, no alpha     → GL_COMPRESSED_RGB_S3TC_DXT1_EXT
    case dxt5   // DXV3 normal, with alpha   → GL_COMPRESSED_RGBA_S3TC_DXT5_EXT
    case ycg6   // DXV3 HQ, no alpha         → custom shader (Phase 2)
    case yg10   // DXV3 HQ, with alpha       → custom shader (Phase 2)

    /// Human-readable label for the title bar / debugging.
    public var displayName: String {
        switch self {
        case .dxt1: return "DXV3"
        case .dxt5: return "DXV3 alpha"
        case .ycg6: return "DXV3 HQ"
        case .yg10: return "DXV3 HQ alpha"
        }
    }
}

/// Codec generation, derived from the trak-level sample-description
/// FourCC. Orthogonal to `DXVVariant` (which is texture format). DXV1
/// and DXV3 differ at the *packet* level — header shape, compression
/// scheme — but agree at the *texture* level (raw DXT1/DXT5 blocks).
///
/// `dxv1`: trak FourCC `DXDI`. 4-byte legacy header, payload is RAW or
/// LZF-compressed DXT blocks. Only `.dxt1` / `.dxt5` variants exist.
/// `dxv3`: trak FourCC `DXD3` (or the texture-format tags). 12-byte
/// header, DXV-specific opcode-based decompression. All four variants.
public enum DXVGeneration {
    case dxv1
    case dxv3
}

/// Complete index built by demuxing a DXV MOV file. After this is built,
/// random-access seek is O(1): just look up frames[i].
public struct DXVMovieIndex {
    public let width: Int
    public let height: Int
    public let variant: DXVVariant
    /// Codec generation. `.dxv3` for the modern Resolume DXV3 family
    /// (trak FourCC `DXD3` or the texture-format tags), `.dxv1` for the
    /// legacy DXV1/DXV2 (trak FourCC `DXDI`). Defaults to `.dxv3` in
    /// the convenience init so prior callers compile unchanged.
    public let generation: DXVGeneration
    public let frames: [DXVFrameEntry]
    /// Total movie duration in seconds.
    public let duration: Double
    /// Average frame rate (frames / duration). Most DXV is CFR; this is
    /// fine for the player clock.
    public var frameRate: Double { duration > 0 ? Double(frames.count) / duration : 30.0 }
    public init(width: Int, height: Int, variant: DXVVariant,
                generation: DXVGeneration = .dxv3,
                frames: [DXVFrameEntry], duration: Double) {
        self.width = width
        self.height = height
        self.variant = variant
        self.generation = generation
        self.frames = frames
        self.duration = duration
    }
}

public enum DXVDemuxError: Error, CustomStringConvertible {
    case fileOpen(String)
    case truncated(String)
    case unsupported(String)
    case missingAtom(String)
    case notDXV(fourCC: String)

    public var description: String {
        switch self {
        case .fileOpen(let s):    return "File open failed: \(s)"
        case .truncated(let s):   return "File truncated: \(s)"
        case .unsupported(let s): return "Unsupported format: \(s)"
        case .missingAtom(let s): return "Missing required atom: \(s)"
        case .notDXV(let f):      return "Not a DXV file (codec FourCC: \(f))"
        }
    }
}

/// MOV atom demuxer specialized for DXV files. Walks the atom tree and
/// builds a frame index. Doesn't read frame payloads — the player does
/// that lazily as it plays.
///
/// MOV files store atoms in a tree: each atom has an 8-byte header
/// (size:UInt32_BE, type:FourCC) followed by either nested atoms or
/// payload bytes. Size includes the 8 header bytes. Size==1 means the
/// real size is in the next 8 bytes (extended size for >4GB). Size==0
/// means "this atom extends to end of file" (rare, mostly mdat).
///
/// We only parse the atoms we need; everything else is skipped.
public final class DXVDemuxer {

    /// Parse a DXV MOV file at `url` and return its frame index. Throws
    /// on malformed or non-DXV files.
    public static func demux(url: URL) throws -> DXVMovieIndex {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw DXVDemuxError.fileOpen(url.path)
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)

        // Walk top-level atoms until we find moov. mdat may come before
        // or after moov in the file (both are valid MOV layouts —
        // "fast start" puts moov first, traditional layout puts it last).
        // We just keep skipping forward until we find what we need.
        var moovOffset: UInt64 = 0
        var moovSize: UInt64 = 0
        var fileOffset: UInt64 = 0
        while fileOffset < fileSize {
            let header = try readAtomHeader(handle, at: fileOffset, fileSize: fileSize)
            if header.type == "moov" {
                moovOffset = fileOffset + UInt64(header.headerSize)
                moovSize = header.totalSize - UInt64(header.headerSize)
                break
            }
            fileOffset += header.totalSize
        }
        guard moovSize > 0 else { throw DXVDemuxError.missingAtom("moov") }

        // Read the entire moov atom into memory. moov is typically small
        // (kilobytes for short clips, megabytes for very long ones) — far
        // smaller than mdat, which we never load whole.
        try handle.seek(toOffset: moovOffset)
        let moovData = try handle.read(upToCount: Int(moovSize)) ?? Data()
        guard moovData.count == Int(moovSize) else {
            throw DXVDemuxError.truncated("moov body")
        }

        var index = try parseMoov(moovData)

        // The trak's codec FourCC is "DXD3" for ALL DXV3 variants — the
        // texture-format tag (DXT1/DXT5/YCG6/YG10) lives in each mdat
        // packet header, not in the trak. Read the first packet's
        // header now to refine the variant. For DXV1 (trak "DXDI") the
        // legacy 4-byte header carries DXT1 vs DXT5 in its flag nibble.
        if let variant = try peekFirstPacketVariant(handle: handle, index: index) {
            index = DXVMovieIndex(
                width: index.width, height: index.height,
                variant: variant, generation: index.generation,
                frames: index.frames,
                duration: index.duration)
        }
        return index
    }

    /// Read the first DXV packet header from the file and decode it into
    /// a refined variant. Branches by generation:
    ///
    /// - `.dxv3`: 12-byte per-packet header:
    ///     bytes 0-3   tag (FourCC, stored little-endian on disk)
    ///     byte 4      version major + 1
    ///     byte 5      version minor
    ///     byte 6      raw flag (1 = uncompressed, 0 = LZF compressed)
    ///     byte 7      unknown
    ///     bytes 8-11  payload size (little-endian UInt32)
    ///
    /// - `.dxv1`: 4-byte legacy header (see `DXV1PacketDecoder`). The
    ///   flag nibble encodes DXT1 vs DXT5; YCG6 / YG10 are DXV3-only.
    ///
    /// Returns nil if the first frame can't be read or the bytes don't
    /// match the generation's expected shape — caller keeps the
    /// demuxer's best-effort variant.
    private static func peekFirstPacketVariant(
        handle: FileHandle, index: DXVMovieIndex
    ) throws -> DXVVariant? {
        guard let firstFrame = index.frames.first else { return nil }
        switch index.generation {
        case .dxv3:
            try handle.seek(toOffset: firstFrame.fileOffset)
            guard let head = try handle.read(upToCount: 12), head.count == 12 else {
                return nil
            }
            let bytes: [UInt8] = [head[3], head[2], head[1], head[0]]
            let tag = String(bytes: bytes, encoding: .ascii) ?? ""
            switch tag {
            case "DXT1": return .dxt1
            case "DXT5": return .dxt5
            case "YCG6": return .ycg6
            case "YG10": return .yg10
            default:     return nil
            }
        case .dxv1:
            try handle.seek(toOffset: firstFrame.fileOffset)
            guard let head = try handle.read(upToCount: 4), head.count == 4 else {
                return nil
            }
            do {
                let h = try DXV1PacketDecoder.parseTagWord(head)
                switch h.textureFormat {
                case .dxt1: return .dxt1
                case .dxt5: return .dxt5
                }
            } catch {
                return nil
            }
        }
    }

    // MARK: - Atom header reader (file-backed)

    private struct AtomHeader {
        let type: String
        let totalSize: UInt64
        let headerSize: Int
    }

    /// Read a single atom header from the file at the given offset.
    /// Returns the type, total size (including header), and how many
    /// bytes the header itself occupies (8 for normal, 16 for extended).
    private static func readAtomHeader(_ handle: FileHandle,
                                       at offset: UInt64,
                                       fileSize: UInt64) throws -> AtomHeader {
        try handle.seek(toOffset: offset)
        guard let head = try handle.read(upToCount: 8), head.count == 8 else {
            throw DXVDemuxError.truncated("atom header at \(offset)")
        }
        let size32 = head.readUInt32BE(at: 0)
        let type = head.readFourCC(at: 4)

        var totalSize: UInt64
        var headerSize: Int = 8
        if size32 == 1 {
            // Extended size in the following 8 bytes.
            guard let ext = try handle.read(upToCount: 8), ext.count == 8 else {
                throw DXVDemuxError.truncated("extended atom size at \(offset)")
            }
            totalSize = ext.readUInt64BE(at: 0)
            headerSize = 16
        } else if size32 == 0 {
            // Atom extends to end of file (only valid for top-level atoms).
            totalSize = fileSize - offset
        } else {
            totalSize = UInt64(size32)
        }
        return AtomHeader(type: type, totalSize: totalSize, headerSize: headerSize)
    }

    // MARK: - Memory-backed atom navigation

    /// Parse the moov atom (already in memory). Walks the trak children
    /// to find a video trak, then dives into its sample table.
    private static func parseMoov(_ data: Data) throws -> DXVMovieIndex {
        var movieTimescale: UInt32 = 600  // sensible default; mvhd will set it
        var videoIndex: DXVMovieIndex?

        try walkAtoms(data) { type, body in
            switch type {
            case "mvhd":
                movieTimescale = parseMvhdTimescale(body)
            case "trak":
                if let idx = try parseTrakIfVideo(body, movieTimescale: movieTimescale) {
                    videoIndex = idx
                    return false  // stop walking once we have the video trak
                }
            default:
                break
            }
            return true
        }

        guard let idx = videoIndex else {
            throw DXVDemuxError.missingAtom("video trak")
        }
        return idx
    }

    /// Read mvhd (movie header) and pull out the timescale. mvhd has two
    /// version variants — version 0 (32-bit times) and version 1 (64-bit
    /// times). The first byte of the body is the version.
    private static func parseMvhdTimescale(_ body: Data) -> UInt32 {
        guard body.count >= 32 else { return 600 }
        let version = body[body.startIndex]
        let timescaleOffset: Int = (version == 1) ? 20 : 12
        guard body.count >= timescaleOffset + 4 else { return 600 }
        return body.readUInt32BE(at: timescaleOffset)
    }

    /// Inspect a trak atom; if it's a video trak, dive in and build the
    /// frame index. Returns nil if this trak is something else (audio,
    /// timecode, etc.).
    private static func parseTrakIfVideo(_ body: Data,
                                         movieTimescale: UInt32) throws -> DXVMovieIndex? {
        var width = 0
        var height = 0
        var mediaTimescale: UInt32 = 0
        var sampleSizes: [UInt32] = []
        var chunkOffsets: [UInt64] = []
        var sampleToChunk: [(firstChunk: UInt32, samplesPerChunk: UInt32, descIdx: UInt32)] = []
        var timeToSample: [(count: UInt32, delta: UInt32)] = []
        var codec: String = ""
        var stsdW: UInt16 = 0
        var stsdH: UInt16 = 0
        var isVideo = false

        try walkAtoms(body) { type, atomBody in
            switch type {
            case "tkhd":
                let dims = parseTkhdDimensions(atomBody)
                width = dims.w
                height = dims.h
            case "mdia":
                try walkAtoms(atomBody) { mtype, mbody in
                    switch mtype {
                    case "mdhd":
                        mediaTimescale = parseMdhdTimescale(mbody)
                    case "hdlr":
                        isVideo = parseHdlrIsVideo(mbody)
                    case "minf":
                        try walkAtoms(mbody) { itype, ibody in
                            if itype == "stbl" {
                                try walkAtoms(ibody) { stype, sbody in
                                    switch stype {
                                    case "stsd":
                                        let info = parseStsd(sbody)
                                        codec = info.codec
                                        stsdW = info.width
                                        stsdH = info.height
                                    case "stsz":
                                        sampleSizes = parseStsz(sbody)
                                    case "stco":
                                        chunkOffsets = parseStco(sbody)
                                    case "co64":
                                        chunkOffsets = parseCo64(sbody)
                                    case "stsc":
                                        sampleToChunk = parseStsc(sbody)
                                    case "stts":
                                        timeToSample = parseStts(sbody)
                                    default: break
                                    }
                                    return true
                                }
                            }
                            return true
                        }
                    default: break
                    }
                    return true
                }
            default: break
            }
            return true
        }

        guard isVideo else { return nil }
        guard mediaTimescale > 0 else {
            throw DXVDemuxError.missingAtom("mdhd timescale")
        }
        guard !sampleSizes.isEmpty else {
            throw DXVDemuxError.missingAtom("stsz")
        }
        guard !chunkOffsets.isEmpty else {
            throw DXVDemuxError.missingAtom("stco/co64")
        }
        guard !sampleToChunk.isEmpty else {
            throw DXVDemuxError.missingAtom("stsc")
        }

        // Resolve the codec FourCC to a DXV variant + generation. The
        // bytes in stsd are stored big-endian as the spec lists them
        // ("DXT1", "DXT5", "YCG6", "YG10"); parseStsd already reads
        // big-endian. The per-packet headers use a different byte
        // order — see peekFirstPacketVariant for that detail.
        //
        // Generation comes from the FourCC: `DXDI` = legacy DXV1/DXV2,
        // everything else = DXV3. For trak-level "version" FourCCs
        // (DXDI, DXD3) the texture format isn't yet known here — we
        // default to `.dxt1` and rely on peekFirstPacketVariant to
        // refine it from the first packet's header.
        let variant: DXVVariant
        let generation: DXVGeneration
        switch codec {
        case "DXT1": variant = .dxt1; generation = .dxv3
        case "DXT5": variant = .dxt5; generation = .dxv3
        case "YCG6": variant = .ycg6; generation = .dxv3
        case "YG10": variant = .yg10; generation = .dxv3
        case "DXD3":
            variant = .dxt1; generation = .dxv3
        case "DXDI":
            variant = .dxt1; generation = .dxv1
        default:
            throw DXVDemuxError.notDXV(fourCC: codec)
        }

        // Prefer stsd-reported dimensions; fall back to tkhd. tkhd's
        // numbers are display-aspect-corrected fixed-point, less reliable
        // for the actual pixel buffer.
        let finalW = stsdW > 0 ? Int(stsdW) : width
        let finalH = stsdH > 0 ? Int(stsdH) : height

        // Build the frame index. Two parallel walks: stsc tells us how
        // samples group into chunks (so we know the file offset of each
        // sample relative to its containing chunk's offset); stts tells
        // us each sample's duration.
        let frames = try buildFrameIndex(
            sampleSizes: sampleSizes,
            chunkOffsets: chunkOffsets,
            sampleToChunk: sampleToChunk,
            timeToSample: timeToSample,
            mediaTimescale: mediaTimescale)

        let duration: Double
        if let last = frames.last {
            // Total duration = last sample's PTS plus its duration.
            // Recover its duration from stts.
            var ttsPos = 0
            var sampleIdx = 0
            var lastDelta: UInt32 = 0
            outer: for entry in timeToSample {
                for _ in 0..<Int(entry.count) {
                    if sampleIdx == frames.count - 1 {
                        lastDelta = entry.delta
                        break outer
                    }
                    sampleIdx += 1
                }
                _ = ttsPos
            }
            duration = last.presentationTime + Double(lastDelta) / Double(mediaTimescale)
        } else {
            duration = 0
        }

        return DXVMovieIndex(
            width: finalW, height: finalH,
            variant: variant, generation: generation,
            frames: frames, duration: duration)
    }

    // MARK: - Atom walking helper

    /// Iterate child atoms within a parent atom's body. The closure is
    /// called with each child's (type, body); returning false stops
    /// iteration. Throws if any atom header is malformed.
    private static func walkAtoms(_ data: Data,
                                  _ visit: (String, Data) throws -> Bool) throws {
        var pos = data.startIndex
        let end = data.endIndex
        while pos + 8 <= end {
            let size32 = data.readUInt32BE(at: pos - data.startIndex)
            let type = data.readFourCC(at: pos - data.startIndex + 4)
            var totalSize: Int
            var headerSize: Int = 8
            if size32 == 1 {
                guard pos + 16 <= end else {
                    throw DXVDemuxError.truncated("extended atom in walkAtoms")
                }
                let ext = data.readUInt64BE(at: pos - data.startIndex + 8)
                totalSize = Int(ext)
                headerSize = 16
            } else if size32 == 0 {
                totalSize = end - pos
            } else {
                totalSize = Int(size32)
            }
            guard totalSize >= headerSize, pos + totalSize <= end else {
                throw DXVDemuxError.truncated("atom body for \(type) at \(pos)")
            }
            let bodyStart = pos + headerSize
            let bodyEnd = pos + totalSize
            let body = data.subdata(in: bodyStart..<bodyEnd)
            let cont = try visit(type, body)
            if !cont { return }
            pos = bodyEnd
        }
    }

    // MARK: - Atom-specific parsers

    private static func parseTkhdDimensions(_ body: Data) -> (w: Int, h: Int) {
        // tkhd structure ends with two 32.16 fixed-point values for
        // width and height. The byte offset depends on version.
        guard !body.isEmpty else { return (0, 0) }
        let version = body[body.startIndex]
        let widthOffset = body.count - 8
        let heightOffset = body.count - 4
        guard widthOffset >= 0, heightOffset >= 0 else { return (0, 0) }
        let w = body.readUInt32BE(at: widthOffset) >> 16
        let h = body.readUInt32BE(at: heightOffset) >> 16
        _ = version
        return (Int(w), Int(h))
    }

    private static func parseMdhdTimescale(_ body: Data) -> UInt32 {
        guard body.count >= 24 else { return 0 }
        let version = body[body.startIndex]
        let offset = (version == 1) ? 20 : 12
        guard body.count >= offset + 4 else { return 0 }
        return body.readUInt32BE(at: offset)
    }

    private static func parseHdlrIsVideo(_ body: Data) -> Bool {
        // hdlr layout: version(1) flags(3) preDefined(4) handlerType(4) ...
        // We want bytes 8..<12 to read as "vide".
        guard body.count >= 12 else { return false }
        let handlerType = body.readFourCC(at: 8)
        return handlerType == "vide"
    }

    /// Parse the sample description atom for a video trak. Returns the
    /// codec FourCC (the "format" field), and the in-pixel width/height
    /// from the visual sample entry.
    private static func parseStsd(_ body: Data) -> (codec: String, width: UInt16, height: UInt16) {
        // stsd: version(1) flags(3) entryCount(4) [entries...]
        // Each entry: size(4) format(4) reserved(6) dataReferenceIndex(2)
        // For visual sample entries: ... a bunch of fixed fields ...
        //   width at offset 32 from start of entry (big-endian UInt16)
        //   height at offset 34
        guard body.count >= 16 else { return ("", 0, 0) }
        let entryCount = body.readUInt32BE(at: 4)
        guard entryCount > 0 else { return ("", 0, 0) }
        let firstEntry = 8
        guard body.count >= firstEntry + 36 else { return ("", 0, 0) }
        let codec = body.readFourCC(at: firstEntry + 4)
        let width = body.readUInt16BE(at: firstEntry + 32)
        let height = body.readUInt16BE(at: firstEntry + 34)
        return (codec, width, height)
    }

    private static func parseStsz(_ body: Data) -> [UInt32] {
        // stsz: version(1) flags(3) sampleSize(4) sampleCount(4) [sizes...]
        // If sampleSize is non-zero, all samples are that size and the
        // table is empty. DXV is typically variable-size, so sampleSize=0
        // and the table follows.
        guard body.count >= 12 else { return [] }
        let constantSize = body.readUInt32BE(at: 4)
        let count = body.readUInt32BE(at: 8)
        if constantSize != 0 {
            return Array(repeating: constantSize, count: Int(count))
        }
        guard body.count >= 12 + Int(count) * 4 else { return [] }
        var sizes = [UInt32](); sizes.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            sizes.append(body.readUInt32BE(at: 12 + i * 4))
        }
        return sizes
    }

    private static func parseStco(_ body: Data) -> [UInt64] {
        // stco: version(1) flags(3) entryCount(4) [offset:4 each]
        guard body.count >= 8 else { return [] }
        let count = body.readUInt32BE(at: 4)
        guard body.count >= 8 + Int(count) * 4 else { return [] }
        var offsets = [UInt64](); offsets.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            offsets.append(UInt64(body.readUInt32BE(at: 8 + i * 4)))
        }
        return offsets
    }

    private static func parseCo64(_ body: Data) -> [UInt64] {
        // co64: 64-bit offset variant. Same layout as stco but 8 bytes
        // per entry. Used in files >4GB.
        guard body.count >= 8 else { return [] }
        let count = body.readUInt32BE(at: 4)
        guard body.count >= 8 + Int(count) * 8 else { return [] }
        var offsets = [UInt64](); offsets.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            offsets.append(body.readUInt64BE(at: 8 + i * 8))
        }
        return offsets
    }

    private static func parseStsc(_ body: Data) -> [(firstChunk: UInt32, samplesPerChunk: UInt32, descIdx: UInt32)] {
        // stsc: version(1) flags(3) entryCount(4) [firstChunk:4 samplesPerChunk:4 descIdx:4]
        guard body.count >= 8 else { return [] }
        let count = body.readUInt32BE(at: 4)
        guard body.count >= 8 + Int(count) * 12 else { return [] }
        var entries: [(UInt32, UInt32, UInt32)] = []
        entries.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let off = 8 + i * 12
            entries.append((
                body.readUInt32BE(at: off),
                body.readUInt32BE(at: off + 4),
                body.readUInt32BE(at: off + 8)
            ))
        }
        return entries
    }

    private static func parseStts(_ body: Data) -> [(count: UInt32, delta: UInt32)] {
        // stts: version(1) flags(3) entryCount(4) [count:4 delta:4]
        guard body.count >= 8 else { return [] }
        let count = body.readUInt32BE(at: 4)
        guard body.count >= 8 + Int(count) * 8 else { return [] }
        var entries: [(UInt32, UInt32)] = []
        entries.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let off = 8 + i * 8
            entries.append((
                body.readUInt32BE(at: off),
                body.readUInt32BE(at: off + 4)
            ))
        }
        return entries
    }

    // MARK: - Frame index assembly

    /// Walk stsc/stco together to compute each sample's absolute file
    /// offset. The math: given sample index i, find which chunk it lives
    /// in (using stsc's compressed run-length representation), then
    /// chunk_offset + sum(sizes of earlier samples in that chunk).
    private static func buildFrameIndex(
        sampleSizes: [UInt32],
        chunkOffsets: [UInt64],
        sampleToChunk: [(firstChunk: UInt32, samplesPerChunk: UInt32, descIdx: UInt32)],
        timeToSample: [(count: UInt32, delta: UInt32)],
        mediaTimescale: UInt32
    ) throws -> [DXVFrameEntry] {
        // Expand the run-length stsc into per-chunk samples-per-chunk.
        // stsc says: "starting at chunk firstChunk, every chunk has
        // samplesPerChunk samples — until the next entry says
        // otherwise." Last entry's run extends to the final chunk.
        var samplesPerChunk = [UInt32](repeating: 0, count: chunkOffsets.count)
        for (i, entry) in sampleToChunk.enumerated() {
            let firstChunkIdx = Int(entry.firstChunk) - 1  // stsc is 1-based
            let lastChunkIdx: Int
            if i + 1 < sampleToChunk.count {
                lastChunkIdx = Int(sampleToChunk[i + 1].firstChunk) - 2
            } else {
                lastChunkIdx = chunkOffsets.count - 1
            }
            guard firstChunkIdx >= 0, lastChunkIdx < chunkOffsets.count else {
                throw DXVDemuxError.truncated("stsc references chunk out of range")
            }
            for c in firstChunkIdx...lastChunkIdx {
                samplesPerChunk[c] = entry.samplesPerChunk
            }
        }

        // For each sample, compute absolute offset.
        var frames: [DXVFrameEntry] = []
        frames.reserveCapacity(sampleSizes.count)

        // stts iterator state — pre-flatten? With short clips it's fine.
        // For correctness, unroll into a per-sample delta array if memory
        // matters. Most DXV is CFR so stts has 1 entry; the unroll is
        // cheap.
        var deltaPerSample = [UInt32](); deltaPerSample.reserveCapacity(sampleSizes.count)
        for entry in timeToSample {
            for _ in 0..<Int(entry.count) {
                deltaPerSample.append(entry.delta)
            }
        }
        // Some files have stts entries that don't sum to exactly the
        // sample count; pad with the last delta to be safe.
        let lastDelta = deltaPerSample.last ?? 1
        while deltaPerSample.count < sampleSizes.count {
            deltaPerSample.append(lastDelta)
        }

        var globalSampleIdx = 0
        var cumulativeTicks: UInt64 = 0
        for (chunkIdx, chunkOffset) in chunkOffsets.enumerated() {
            let n = Int(samplesPerChunk[chunkIdx])
            var offsetInChunk: UInt64 = 0
            for _ in 0..<n {
                guard globalSampleIdx < sampleSizes.count else {
                    // stsc claims more samples than stsz lists — file
                    // disagreement; bail out cleanly.
                    return frames
                }
                let size = sampleSizes[globalSampleIdx]
                let pts = Double(cumulativeTicks) / Double(mediaTimescale)
                frames.append(DXVFrameEntry(
                    fileOffset: chunkOffset + offsetInChunk,
                    size: size,
                    presentationTime: pts))
                offsetInChunk += UInt64(size)
                cumulativeTicks += UInt64(deltaPerSample[globalSampleIdx])
                globalSampleIdx += 1
            }
        }
        return frames
    }
}

// MARK: - Data extension helpers

private extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let i = startIndex + offset
        return (UInt16(self[i]) << 8) | UInt16(self[i + 1])
    }
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let i = startIndex + offset
        return (UInt32(self[i]) << 24)
             | (UInt32(self[i + 1]) << 16)
             | (UInt32(self[i + 2]) << 8)
             | UInt32(self[i + 3])
    }
    func readUInt64BE(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        let i = startIndex + offset
        var v: UInt64 = 0
        for k in 0..<8 { v = (v << 8) | UInt64(self[i + k]) }
        return v
    }
    func readFourCC(at offset: Int) -> String {
        guard offset + 4 <= count else { return "" }
        let i = startIndex + offset
        let bytes = [self[i], self[i + 1], self[i + 2], self[i + 3]]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
