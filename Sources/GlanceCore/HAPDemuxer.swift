// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation

/// One HAP frame's location in a MOV file. `fileOffset` and `size`
/// cover the full HAP frame packet — the 4-byte (or 8-byte) section
/// header AND the section payload — since the header is what tells
/// the packet decoder how to interpret the payload (raw DXT vs
/// Snappy-compressed). Shape mirrors `DXVFrameEntry`.
public struct HAPFrameEntry: Sendable, Equatable {
    public let fileOffset: UInt64
    public let size: UInt32
    /// Seconds from the start of the movie.
    public let presentationTime: Double
    public init(fileOffset: UInt64, size: UInt32, presentationTime: Double) {
        self.fileOffset = fileOffset
        self.size = size
        self.presentationTime = presentationTime
    }
}

/// HAP family variant identified at the trak's sample description.
/// All five FourCCs are enumerated so callers can pattern-match
/// exhaustively; Phase 6.a implements decode for `.hap1` only,
/// 6.a's follow-on pass adds `.hap5`, and 6.b adds the HapQ variants
/// (`.hapY`, `.hapM`, `.hapA`).
public enum HAPVariant: Sendable, Equatable {
    case hap1   // Hap1 → RGB DXT1 (no alpha)
    case hap5   // Hap5 → RGBA DXT5 (with alpha)
    case hapY   // HapY → Scaled YCoCg DXT5 (HapQ); decoded in 6.b
    case hapM   // HapM → HapQ + Alpha (two-texture multi-section); 6.b
    case hapA   // HapA → Alpha-only RGTC1; 6.b

    /// Human-readable label that matches `DXVDetector.displayName(for:)`.
    public var displayName: String {
        switch self {
        case .hap1: return "HAP"
        case .hap5: return "HAP Alpha"
        case .hapY: return "HAP Q"
        case .hapM: return "HAP Q Alpha"
        case .hapA: return "HAP Alpha-only"
        }
    }
}

/// Complete index built by demuxing a HAP MOV file. After this is
/// built, random-access seek is O(1): just look up `frames[i]`.
/// Same shape as `DXVMovieIndex`.
public struct HAPMovieIndex: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let variant: HAPVariant
    public let frames: [HAPFrameEntry]
    /// Total movie duration in seconds.
    public let duration: Double
    /// Average frame rate (frames / duration). Most HAP is CFR; this
    /// is fine for player clock purposes.
    public var frameRate: Double { duration > 0 ? Double(frames.count) / duration : 30.0 }
    public init(width: Int, height: Int, variant: HAPVariant, frames: [HAPFrameEntry], duration: Double) {
        self.width = width
        self.height = height
        self.variant = variant
        self.frames = frames
        self.duration = duration
    }
}

public enum HAPDemuxError: Error, CustomStringConvertible {
    case fileOpen(String)
    case truncated(String)
    case unsupported(String)
    case missingAtom(String)
    case notHAP(fourCC: String)

    public var description: String {
        switch self {
        case .fileOpen(let s):    return "File open failed: \(s)"
        case .truncated(let s):   return "File truncated: \(s)"
        case .unsupported(let s): return "Unsupported format: \(s)"
        case .missingAtom(let s): return "Missing required atom: \(s)"
        case .notHAP(let f):      return "Not a HAP file (codec FourCC: \(f))"
        }
    }
}

/// MOV atom demuxer specialised for HAP files. Mirrors
/// `DXVDemuxer`'s structure — same MOV-walking pattern, same frame-
/// index assembly, different variant detection. The MOV container
/// layout is identical between DXV and HAP, so the parsing helpers
/// below are functionally equivalent to `DXVDemuxer`'s private
/// helpers; duplicated rather than refactored out so Phase 6.a stays
/// non-invasive. A future Phase 7+ task could extract the shared
/// MOV parsing into a single `MOVAtomParser` if a third codec
/// family arrives.
public final class HAPDemuxer {

    /// Parse a HAP MOV file at `url` and return its frame index.
    /// Throws on malformed input or non-HAP codec FourCC.
    public static func demux(url: URL) throws -> HAPMovieIndex {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw HAPDemuxError.fileOpen(url.path)
        }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        try handle.seek(toOffset: 0)

        // Find moov. Same fast-start-or-traditional layout handling
        // as DXVDemuxer: keep walking top-level atoms until we hit
        // one whose type is "moov".
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
        guard moovSize > 0 else { throw HAPDemuxError.missingAtom("moov") }

        try handle.seek(toOffset: moovOffset)
        let moovData = try handle.read(upToCount: Int(moovSize)) ?? Data()
        guard moovData.count == Int(moovSize) else {
            throw HAPDemuxError.truncated("moov body")
        }

        return try parseMoov(moovData)
    }

    // MARK: - Atom header reader (file-backed)

    private struct AtomHeader {
        let type: String
        let totalSize: UInt64
        let headerSize: Int
    }

    private static func readAtomHeader(_ handle: FileHandle,
                                       at offset: UInt64,
                                       fileSize: UInt64) throws -> AtomHeader {
        try handle.seek(toOffset: offset)
        guard let head = try handle.read(upToCount: 8), head.count == 8 else {
            throw HAPDemuxError.truncated("atom header at \(offset)")
        }
        let size32 = head.readUInt32BE(at: 0)
        let type = head.readFourCC(at: 4)

        var totalSize: UInt64
        var headerSize: Int = 8
        if size32 == 1 {
            guard let ext = try handle.read(upToCount: 8), ext.count == 8 else {
                throw HAPDemuxError.truncated("extended atom size at \(offset)")
            }
            totalSize = ext.readUInt64BE(at: 0)
            headerSize = 16
        } else if size32 == 0 {
            totalSize = fileSize - offset
        } else {
            totalSize = UInt64(size32)
        }
        return AtomHeader(type: type, totalSize: totalSize, headerSize: headerSize)
    }

    // MARK: - Memory-backed atom navigation

    private static func parseMoov(_ data: Data) throws -> HAPMovieIndex {
        var movieTimescale: UInt32 = 600
        var videoIndex: HAPMovieIndex?

        try walkAtoms(data) { type, body in
            switch type {
            case "mvhd":
                movieTimescale = parseMvhdTimescale(body)
            case "trak":
                if let idx = try parseTrakIfVideo(body, movieTimescale: movieTimescale) {
                    videoIndex = idx
                    return false  // stop walking once we have it
                }
            default: break
            }
            return true
        }

        guard let idx = videoIndex else {
            throw HAPDemuxError.missingAtom("video trak")
        }
        return idx
    }

    private static func parseMvhdTimescale(_ body: Data) -> UInt32 {
        guard body.count >= 32 else { return 600 }
        let version = body[body.startIndex]
        let timescaleOffset: Int = (version == 1) ? 20 : 12
        guard body.count >= timescaleOffset + 4 else { return 600 }
        return body.readUInt32BE(at: timescaleOffset)
    }

    private static func parseTrakIfVideo(_ body: Data,
                                         movieTimescale: UInt32) throws -> HAPMovieIndex? {
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
            throw HAPDemuxError.missingAtom("mdhd timescale")
        }
        guard !sampleSizes.isEmpty else {
            throw HAPDemuxError.missingAtom("stsz")
        }
        guard !chunkOffsets.isEmpty else {
            throw HAPDemuxError.missingAtom("stco/co64")
        }
        guard !sampleToChunk.isEmpty else {
            throw HAPDemuxError.missingAtom("stsc")
        }

        // Map codec FourCC to HAPVariant.
        let variant: HAPVariant
        switch codec {
        case "Hap1": variant = .hap1
        case "Hap5": variant = .hap5
        case "HapY": variant = .hapY
        case "HapM": variant = .hapM
        case "HapA": variant = .hapA
        default:
            throw HAPDemuxError.notHAP(fourCC: codec)
        }

        let finalW = stsdW > 0 ? Int(stsdW) : width
        let finalH = stsdH > 0 ? Int(stsdH) : height

        let frames = try buildFrameIndex(
            sampleSizes: sampleSizes,
            chunkOffsets: chunkOffsets,
            sampleToChunk: sampleToChunk,
            timeToSample: timeToSample,
            mediaTimescale: mediaTimescale)

        let duration: Double
        if let last = frames.last {
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
            }
            duration = last.presentationTime + Double(lastDelta) / Double(mediaTimescale)
        } else {
            duration = 0
        }

        return HAPMovieIndex(
            width: finalW, height: finalH,
            variant: variant, frames: frames, duration: duration)
    }

    // MARK: - Atom walking helper

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
                    throw HAPDemuxError.truncated("extended atom in walkAtoms")
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
                throw HAPDemuxError.truncated("atom body for \(type) at \(pos)")
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
        guard !body.isEmpty else { return (0, 0) }
        let widthOffset = body.count - 8
        let heightOffset = body.count - 4
        guard widthOffset >= 0, heightOffset >= 0 else { return (0, 0) }
        let w = body.readUInt32BE(at: widthOffset) >> 16
        let h = body.readUInt32BE(at: heightOffset) >> 16
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
        guard body.count >= 12 else { return false }
        let handlerType = body.readFourCC(at: 8)
        return handlerType == "vide"
    }

    private static func parseStsd(_ body: Data) -> (codec: String, width: UInt16, height: UInt16) {
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

    private static func buildFrameIndex(
        sampleSizes: [UInt32],
        chunkOffsets: [UInt64],
        sampleToChunk: [(firstChunk: UInt32, samplesPerChunk: UInt32, descIdx: UInt32)],
        timeToSample: [(count: UInt32, delta: UInt32)],
        mediaTimescale: UInt32
    ) throws -> [HAPFrameEntry] {
        var samplesPerChunk = [UInt32](repeating: 0, count: chunkOffsets.count)
        for (i, entry) in sampleToChunk.enumerated() {
            let firstChunkIdx = Int(entry.firstChunk) - 1
            let lastChunkIdx: Int
            if i + 1 < sampleToChunk.count {
                lastChunkIdx = Int(sampleToChunk[i + 1].firstChunk) - 2
            } else {
                lastChunkIdx = chunkOffsets.count - 1
            }
            guard firstChunkIdx >= 0, lastChunkIdx < chunkOffsets.count else {
                throw HAPDemuxError.truncated("stsc references chunk out of range")
            }
            for c in firstChunkIdx...lastChunkIdx {
                samplesPerChunk[c] = entry.samplesPerChunk
            }
        }

        var frames: [HAPFrameEntry] = []
        frames.reserveCapacity(sampleSizes.count)

        var deltaPerSample = [UInt32](); deltaPerSample.reserveCapacity(sampleSizes.count)
        for entry in timeToSample {
            for _ in 0..<Int(entry.count) {
                deltaPerSample.append(entry.delta)
            }
        }
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
                    return frames
                }
                let size = sampleSizes[globalSampleIdx]
                let pts = Double(cumulativeTicks) / Double(mediaTimescale)
                frames.append(HAPFrameEntry(
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

/// HAP-private copies of the byte readers used by `DXVDemuxer`. Same
/// signatures and semantics; duplicated rather than reused because
/// the DXV ones are `fileprivate` to that demuxer. If a future
/// refactor extracts a shared MOV parser, these collapse into one
/// extension.
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
