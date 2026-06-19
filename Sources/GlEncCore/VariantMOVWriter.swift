// SPDX-License-Identifier: MIT
/*
 * VariantMOVWriter — hand-rolled MOV atom writer for codecs AVFoundation
 * doesn't understand natively (DXV3 + HAP variants).
 *
 * v0.9.1 Phase C renamed this from DXVMOVWriter and added the
 * `codecFourCC` parameter so the same atom-emission code handles
 * HAP1/HAP5/HapY containers in addition to DXV3. The atom structure
 * is identical across all variants — only the codec FourCC in stsd
 * and the encoder identity string in udta ©swr differ. A public
 * typealias `DXVMOVWriter = VariantMOVWriter` (at the end of this
 * file) keeps every existing caller (EncodeQueue, EncodePipeline,
 * 8 test files) compiling with zero changes.
 *
 * Replaces AVAssetWriter for the DXV3 encode path. AVAssetWriter doesn't
 * understand DXV3 natively, registering a custom codec plugin would be
 * heavy and Apple-platform-locked, and Pass A archaeology requires
 * byte-exact atom control (DECISIONS-2026-05-09.md decision 4).
 *
 * Spec invariants enforced (Pass A FINDINGS.md, three-encoder agreement):
 *   - Stream-level codec FourCC: DXD3.
 *   - Per-frame DXV3 header is little-endian; the encoder produces it.
 *     Everything in this writer is BIG-endian (MOV atom convention).
 *   - tkhd carries presentation width/height, NOT 16-aligned coded dims.
 *   - stsd substantive fields: vendor FFMP, depth 24, color-table-id 0xFFFF,
 *     presentation dims, 72 DPI both axes.
 *   - stbl skeleton order: stsd → stts → stsc → stsz → stco.
 *
 * Encoder-discretion choices (mirroring Alley):
 *   - moov at end-of-file (write-as-you-go; mdat first, then moov).
 *   - udta minimal: single ©swr = "GlEnc <version>".
 *   - stsd: NO extension atoms (no fiel/pasp/encoder-name).
 *   - One sample per chunk (Alley shape). stsc has one entry with
 *     samples_per_chunk=1, stco has N offsets (one per sample). Phase 7A
 *     Finding 6 surfaced that the prior "one chunk total" layout — though
 *     a valid MOV that ffmpeg/CPURender handle correctly — produced skew
 *     in Resolume Arena. Arena evidently mis-walks samples when stsc
 *     reports >1 sample/chunk; matching Alley's per-sample chunking is
 *     the smallest fix that keeps Arena happy.
 *
 * mdat size form: 32-bit. Phase 2A's 30-frame testsrc2 corpus is ~2.4 MB;
 * the writer fails fast if a future workload produces an mdat ≥ 4 GB.
 * Switching to 64-bit largesize is a 12-byte header rewrite when the time
 * comes.
 */

import Foundation
import CoreMedia

public final class VariantMOVWriter {

    public enum WriterError: Error, CustomStringConvertible {
        case alreadyFinished
        case notInitialized
        case mdatExceeds4GB(size: UInt64)
        case nonIntegerFPS(Double)
        case ioError(Error)
        case invalidCodecFourCC(String)
        /// Fix-Brief 3 (E) — the audio trak's absolute chunk offset would
        /// exceed UInt32.max (the 32-bit `stco` limit) — i.e. ~4 GB of video
        /// precedes the audio. Thrown BEFORE the stco is written so it can't
        /// truncate to a garbage offset (silent-wrong audio). 64-bit `co64`
        /// is deferred post-1.0.0.
        case audioOffsetExceeds4GB(offset: UInt64)
        public var description: String {
            switch self {
            case .alreadyFinished: return "VariantMOVWriter: append/finish called after finish()"
            case .notInitialized:  return "VariantMOVWriter: append called on non-initialized writer"
            case .mdatExceeds4GB(let s):
                return "VariantMOVWriter: mdat body would be \(s) bytes (>4GB); 64-bit size form needed"
            case .nonIntegerFPS(let f):
                return "VariantMOVWriter: fps \(f) is not an integer; mdhd timescale derivation requires integer fps"
            case .ioError(let e):
                return "VariantMOVWriter: I/O error: \(e)"
            case .invalidCodecFourCC(let s):
                return "VariantMOVWriter: codecFourCC must be exactly 4 ASCII bytes; got \(s.debugDescription)"
            case .audioOffsetExceeds4GB(let o):
                return "VariantMOVWriter: audio chunk offset \(o) exceeds 4GB (32-bit stco limit); co64 not yet supported"
            }
        }
    }

    private let destURL: URL
    private let format: DXVFormat
    /// 4-byte ASCII codec identifier written to the stsd sample entry's
    /// "sample format" field. DXV3 callers pass "DXD3" (the default
    /// preserves legacy DXVMOVWriter behaviour byte-exact); HAP callers
    /// pass "Hap1" / "Hap5" / "HapY".
    private let codecFourCC: String
    private let presentationWidth: UInt16
    private let presentationHeight: UInt16
    private let mvhdTimescale: UInt32 = 1000
    /// Integer-rate convention: media timescale = fps × `ticksPerFrame`,
    /// per-sample delta = `ticksPerFrame` (matches ffmpeg's DXV output,
    /// e.g. 30fps → timescale 15360, delta 512). NTSC rates use the
    /// `(N×1000, 1001)` basis instead. Both reduce to the same atom math
    /// once expressed as `(mediaTimescale, sampleDelta)`.
    private static let ticksPerFrame: UInt32 = 512
    /// Resolved media timescale (mdhd) — fps×512 for integer rates,
    /// 30000/24000 for the NTSC rates. See `deriveTimescale`.
    private let mediaTimescale: UInt32
    /// Resolved per-sample duration (stts sample_delta) — 512 for
    /// integer rates, 1001 for NTSC.
    private let sampleDelta: UInt32
    private let writerVersion: String

    private var fileHandle: FileHandle?
    private var mdatHeaderOffset: UInt64 = 0
    private var mdatBodySize: UInt64 = 0
    private var firstChunkOffset: UInt64 = 0
    private var sampleSizes: [UInt32] = []
    private var finished = false

    // Phase 4 — optional second audio trak. nil (the default) → the
    // EXACT pre-audio code path: no audio bytes in mdat, single video
    // trak in moov, mvhd unchanged → byte-identical (the 8 named gate
    // tests prove it). Set via `attachAudioTrack` before `finish()`.
    private var audioInfo: AudioStreamInfo?
    private var audioPCM: Data = Data()
    /// mdat offset where the audio PCM region begins (after all video).
    private var audioChunkOffset: UInt64 = 0

    public init(
        destURL: URL,
        format: DXVFormat,
        presentationWidth: Int,
        presentationHeight: Int,
        fps: Double,
        // v0.9.2 Phase D.5: default is "GlEnc" with no version number.
        // Real users go through EncodeQueue's WriterFactory, which
        // passes `AppVersion.writerVersion` (read from
        // CFBundleShortVersionString) — single source of truth, can't
        // drift from the real app version. Tests pinned to historical
        // reference files pass their own writerVersion literal
        // explicitly. The pre-D.5 default of "GlEnc 0.2.0" was a stale
        // Phase 2B literal that leaked into shipped MOVs because
        // EncodeQueue never passed writerVersion.
        writerVersion: String = "GlEnc",
        codecFourCC: String = "DXD3"
    ) throws {
        precondition(presentationWidth > 0 && presentationWidth <= Int(UInt16.max))
        precondition(presentationHeight > 0 && presentationHeight <= Int(UInt16.max))
        // #14 part 2 — resolve (mediaTimescale, sampleDelta). Integer
        // rates keep ffmpeg's ×512 basis byte-identically; the two NTSC
        // rates (29.97, 23.976) take the (N×1000, 1001) basis. Anything
        // else still throws nonIntegerFPS.
        let (resolvedTimescale, resolvedDelta) = try Self.deriveTimescale(fps: fps)
        // codecFourCC must be exactly 4 ASCII bytes — MOV's sample
        // format field is a fixed-size 4-byte slot.
        let ccBytes = codecFourCC.utf8
        guard ccBytes.count == 4, ccBytes.allSatisfy({ $0 < 128 }) else {
            throw WriterError.invalidCodecFourCC(codecFourCC)
        }
        self.destURL = destURL
        self.format = format
        self.codecFourCC = codecFourCC
        self.presentationWidth = UInt16(presentationWidth)
        self.presentationHeight = UInt16(presentationHeight)
        self.mediaTimescale = resolvedTimescale
        self.sampleDelta = resolvedDelta
        self.writerVersion = writerVersion
        FileHandle.standardError.write(Data(
            ("[GlEnc/writer-fps] fps=\(fps) → mediaTimescale=\(resolvedTimescale) " +
             "sampleDelta=\(resolvedDelta) (rate=\(Double(resolvedTimescale)/Double(resolvedDelta)))\n").utf8))

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        FileManager.default.createFile(atPath: destURL.path, contents: nil, attributes: nil)
        self.fileHandle = try FileHandle(forWritingTo: destURL)

        // Fix-Brief 3 (7.3) — if any preamble write throws, close the handle
        // we just opened (no deinit existed → it would leak until ARC). On
        // success `initOK` is set, so the handle stays open for append/finish.
        var initOK = false
        defer { if !initOK { try? fileHandle?.close(); fileHandle = nil } }
        try writeFTYP()
        try writeWide()
        try writeMDATHeader()
        initOK = true
    }

    /// Dealloc-time HYGIENE BACKSTOP — closes `fileHandle` iff no scope-level
    /// path already did. NOT a leak fix: `FileHandle(forWritingTo:)` already
    /// closes its own fd on its dealloc, so the fd is freed at this same
    /// moment regardless. The value is making the close explicit + unconditional
    /// at the type level, consistent with the Brief-3 defers, and a backstop
    /// for any future path that leaves the handle non-nil.
    ///
    /// The three scope-level paths all close + nil `fileHandle` earlier, so
    /// this sees `nil` and no-ops on them: success (`finish()`), init-throw
    /// (init's success-flag defer), finish-throw (finish's top-of-scope defer).
    /// The only path with no scope-level close is an `append()` throw on an
    /// abandoned writer (created, a write throws, dropped without `finish()`) —
    /// there the handle is still non-nil and this closes it. `try?` + the
    /// `fileHandle?` nil-check make a double-close impossible. Writes no bytes.
    deinit { try? fileHandle?.close() }

    /// Resolve `fps` to `(mediaTimescale, sampleDelta)` for the media
    /// (mdhd/stts) atoms. Three accepted cases; everything else throws:
    ///   - Integer N → `(N × ticksPerFrame, ticksPerFrame)` = `(N×512,
    ///     512)`. This reproduces the legacy/ffmpeg integer layout
    ///     byte-for-byte (the only change is expressing it via this
    ///     pair).
    ///   - 29.97 (N=30) → `(30000, 1001)`; 23.976 (N=24) → `(24000,
    ///     1001)`. The NTSC `(N×1000, 1001)` basis, confirmed against
    ///     ffmpeg's DXV output.
    /// ε is deliberately tiny: part 1 derives the rate from the track's
    /// exact `minFrameDuration`, so a true NTSC source arrives as
    /// `Double(N*1000)/Double(1001)` and the residual is ~0. The nearest
    /// rejected rate, 29.5, sits |29.5 − 30000/1001| ≈ 0.47 away — many
    /// orders of magnitude beyond ε, so it cannot false-match. Only the
    /// two validated NTSC rates are accepted; 59.94/119.88 are
    /// deliberately NOT included (unvalidated output).
    static func deriveTimescale(fps: Double) throws -> (UInt32, UInt32) {
        let n = fps.rounded()
        if abs(fps - n) < 1e-6 {
            return (UInt32(n) * ticksPerFrame, ticksPerFrame)
        }
        let eps = 1e-6
        for nN in [30, 24] {
            let ntsc = Double(nN) * 1000.0 / 1001.0
            if abs(fps - ntsc) < eps {
                return (UInt32(nN) * 1000, 1001)
            }
        }
        throw WriterError.nonIntegerFPS(fps)
    }

    /// Fix-Brief 3 (E) — pure check: does an absolute audio chunk offset fit
    /// the 32-bit `stco` field? `UInt32(offset)` would silently truncate past
    /// this, pointing the audio trak at garbage. Unit seam.
    public static func audioChunkOffsetFitsStco(_ offset: UInt64) -> Bool {
        offset <= UInt64(UInt32.max)
    }

    public func append(packet: Data, presentationTime: CMTime) throws {
        guard !finished else { throw WriterError.alreadyFinished }
        guard let fh = fileHandle else { throw WriterError.notInitialized }
        if sampleSizes.isEmpty {
            firstChunkOffset = try fh.offset()
        }
        try fh.write(contentsOf: packet)
        sampleSizes.append(UInt32(packet.count))
        mdatBodySize += UInt64(packet.count)
    }

    /// Phase 4 — attach a second LPCM (`in32`, 32-bit signed LE) audio
    /// trak, written when `finish()` runs. Audio PCM is appended to mdat
    /// AFTER all video (so video chunk offsets never move → video bytes
    /// stay identical), and a second `trak` is added to moov. Call before
    /// `finish()`. Not calling it leaves the writer byte-identical to the
    /// pre-audio path. `pcm` is interleaved 32-bit signed little-endian.
    public func attachAudioTrack(info: AudioStreamInfo, pcm: Data) {
        guard !finished, info.bytesPerFrame > 0, !pcm.isEmpty else { return }
        self.audioInfo = info
        self.audioPCM = pcm
    }

    public func finish() throws {
        guard !finished else { throw WriterError.alreadyFinished }
        guard let fh = fileHandle else { throw WriterError.notInitialized }

        // Fix-Brief 3 (F2/7.2/7.4) — close the handle on EVERY exit. The
        // success path closes + nils `fileHandle` below (which still surfaces
        // a close error via `try`), so on success this defer sees nil and is
        // a no-op (no double-close). On any throw between here and that close
        // (audio write, the >4GB guards, the mdat/moov writes) it closes the
        // fd that would otherwise leak (no deinit). It writes no bytes, so
        // the success-path byte sequence is untouched.
        defer { try? fileHandle?.close(); fileHandle = nil }

        // Phase 4 — append audio PCM into mdat AFTER all video packets.
        // Video chunk offsets were recorded as video was written, so they
        // are unaffected; the audio region begins at the current EOF.
        if audioInfo != nil, !audioPCM.isEmpty {
            audioChunkOffset = try fh.offset()
            // Fix-Brief 3 (E) — the audio chunk's ABSOLUTE file offset
            // (36-byte preamble + all video) can exceed UInt32.max even when
            // the mdat-body guard below passes (small audio after ~4 GB of
            // video). Writing it would truncate the stco offset → audio
            // points to garbage (silent-wrong). Fail loud with a clear error
            // instead; proper 64-bit `co64` is deferred post-1.0.0.
            guard Self.audioChunkOffsetFitsStco(audioChunkOffset) else {
                throw WriterError.audioOffsetExceeds4GB(offset: audioChunkOffset)
            }
            try fh.write(contentsOf: audioPCM)
            mdatBodySize += UInt64(audioPCM.count)
        }

        // Patch mdat header with the final 32-bit size (video + audio).
        let mdatSize = 8 + mdatBodySize
        guard mdatSize <= UInt64(UInt32.max) else {
            throw WriterError.mdatExceeds4GB(size: mdatBodySize)
        }
        try fh.seek(toOffset: mdatHeaderOffset)
        try fh.write(contentsOf: Data(beBytes32(UInt32(mdatSize))))

        // Append moov at end-of-file.
        try fh.seekToEnd()
        let moov = buildMoov()
        try fh.write(contentsOf: moov)
        try fh.synchronize()
        try fh.close()
        fileHandle = nil
        finished = true
    }

    // MARK: - Atom writers (preamble: ftyp, wide, mdat header)

    private func writeFTYP() throws {
        guard let fh = fileHandle else { throw WriterError.notInitialized }
        // body: major brand "qt  " + minor 0x00000200 + compatible "qt  "
        var body = Data()
        body.append(contentsOf: ascii("qt  "))
        body.append(contentsOf: beBytes32(0x00000200))
        body.append(contentsOf: ascii("qt  "))
        var atom = Data()
        wrapAtom(into: &atom, type: "ftyp", body: body)
        try fh.write(contentsOf: atom)
    }

    private func writeWide() throws {
        guard let fh = fileHandle else { throw WriterError.notInitialized }
        var atom = Data()
        wrapAtom(into: &atom, type: "wide", body: Data())
        try fh.write(contentsOf: atom)
    }

    private func writeMDATHeader() throws {
        guard let fh = fileHandle else { throw WriterError.notInitialized }
        mdatHeaderOffset = try fh.offset()
        // Placeholder size (patched in finish()) + "mdat".
        var hdr = Data()
        hdr.append(contentsOf: beBytes32(0))
        hdr.append(contentsOf: ascii("mdat"))
        try fh.write(contentsOf: hdr)
    }

    // MARK: - moov assembly

    private func buildMoov() -> Data {
        var moov = Data()
        wrapAtom(into: &moov, type: "moov", body: buildMoovBody())
        return moov
    }

    private func buildMoovBody() -> Data {
        var body = Data()
        appendAtom(into: &body, type: "mvhd", body: mvhdBody())
        appendAtom(into: &body, type: "trak", body: trakBody())
        // Phase 4 — second audio trak, present ONLY when audio attached.
        // Order matches Alley: mvhd, video trak, audio trak, udta.
        if audioInfo != nil, !audioPCM.isEmpty {
            appendAtom(into: &body, type: "trak", body: audioTrakBody())
        }
        appendAtom(into: &body, type: "udta", body: udtaBody())
        return body
    }

    /// Audio duration in the movie (mvhd) timescale. 0 when no audio.
    private var audioDurationMS: UInt64 {
        guard let info = audioInfo, info.bytesPerFrame > 0, info.sampleRate > 0 else { return 0 }
        let frames = UInt64(audioPCM.count / info.bytesPerFrame)
        return frames * UInt64(mvhdTimescale) / UInt64(info.sampleRate)
    }

    /// mvhd v0 (100-byte body) — byte-identical to ffmpeg.mov's & alley.mov's
    /// mvhd for 1 second @ mvhd_timescale=1000.
    private func mvhdBody() -> Data {
        let frameCount = UInt32(sampleSizes.count)
        // Movie duration in mvhd timescale (ms). For integer fps and integer
        // frame count, this is exact; otherwise rounded.
        let videoDurMS = UInt64(frameCount) * UInt64(mvhdTimescale) * UInt64(sampleDelta) / UInt64(mediaTimescale)
        // Phase 4 — with audio, movie duration is the longer track and
        // next_track_id advances to 3. With NO audio these are exactly the
        // pre-audio values (videoDurMS, 2) → byte-identical.
        let hasAudio = (audioInfo != nil && !audioPCM.isEmpty)
        let durMS = hasAudio ? max(videoDurMS, audioDurationMS) : videoDurMS
        let nextTrackID: UInt32 = hasAudio ? 3 : 2
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(0))                  // creation_time
        b.append(contentsOf: beBytes32(0))                  // modification_time
        b.append(contentsOf: beBytes32(mvhdTimescale))      // timescale = 1000
        b.append(contentsOf: beBytes32(UInt32(durMS)))      // duration
        b.append(contentsOf: beBytes32(0x00010000))         // rate = 1.0 (16.16)
        b.append(contentsOf: beBytes16(0x0100))             // volume = 1.0 (8.8)
        b.append(contentsOf: beBytes16(0))                  // reserved
        b.append(contentsOf: [UInt8](repeating: 0, count: 8))   // 2× reserved uint32
        b.append(contentsOf: identityMatrix())              // 36 bytes
        b.append(contentsOf: [UInt8](repeating: 0, count: 24))  // pre_defined (6× uint32)
        b.append(contentsOf: beBytes32(nextTrackID))        // next_track_id
        return b
    }

    /// trak body = tkhd + edts/elst + mdia.
    private func trakBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "tkhd", body: tkhdBody())
        appendAtom(into: &b, type: "edts", body: edtsBody())
        appendAtom(into: &b, type: "mdia", body: mdiaBody())
        return b
    }

    /// tkhd v0 (84-byte body). Flags 0x000003 = ENABLED + IN_MOVIE.
    /// Width/height carry PRESENTATION dims per Pass A invariant.
    private func tkhdBody() -> Data {
        let frameCount = UInt32(sampleSizes.count)
        let durMS = UInt64(frameCount) * UInt64(mvhdTimescale) * UInt64(sampleDelta) / UInt64(mediaTimescale)
        var b = Data()
        b.append(contentsOf: beBytes32(0x00000003))         // version+flags
        b.append(contentsOf: beBytes32(0))                  // creation_time
        b.append(contentsOf: beBytes32(0))                  // modification_time
        b.append(contentsOf: beBytes32(1))                  // track_id
        b.append(contentsOf: beBytes32(0))                  // reserved
        b.append(contentsOf: beBytes32(UInt32(durMS)))      // duration (movie ts)
        b.append(contentsOf: [UInt8](repeating: 0, count: 8))   // reserved
        b.append(contentsOf: beBytes16(0))                  // layer
        b.append(contentsOf: beBytes16(0))                  // alternate_group
        b.append(contentsOf: beBytes16(0))                  // volume = 0 for video
        b.append(contentsOf: beBytes16(0))                  // reserved
        b.append(contentsOf: identityMatrix())              // 36 bytes
        // width/height: 16.16 fixed
        b.append(contentsOf: beBytes32(UInt32(presentationWidth) << 16))
        b.append(contentsOf: beBytes32(UInt32(presentationHeight) << 16))
        return b
    }

    /// edts/elst: one entry mapping the whole track at rate 1.0.
    private func edtsBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "elst", body: elstBody())
        return b
    }

    private func elstBody() -> Data {
        let frameCount = UInt32(sampleSizes.count)
        let durMS = UInt64(frameCount) * UInt64(mvhdTimescale) * UInt64(sampleDelta) / UInt64(mediaTimescale)
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(1))                  // entry_count
        b.append(contentsOf: beBytes32(UInt32(durMS)))      // segment_duration
        b.append(contentsOf: beBytes32(0))                  // media_time
        b.append(contentsOf: beBytes32(0x00010000))         // media_rate = 1.0 (16.16)
        return b
    }

    /// mdia body = mdhd + hdlr + minf.
    private func mdiaBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "mdhd", body: mdhdBody())
        appendAtom(into: &b, type: "hdlr", body: hdlrMdiaBody())
        appendAtom(into: &b, type: "minf", body: minfBody())
        return b
    }

    /// mdhd v0 (24-byte body). Language 0x55c4 = "und" (undetermined).
    private func mdhdBody() -> Data {
        let frameCount = UInt32(sampleSizes.count)
        let mediaDuration = frameCount * sampleDelta
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(0))                  // creation
        b.append(contentsOf: beBytes32(0))                  // modification
        b.append(contentsOf: beBytes32(mediaTimescale))     // timescale
        b.append(contentsOf: beBytes32(mediaDuration))      // duration
        // ffmpeg.mov / alley.mov both write `7f ff 00 00` here. The high bit
        // (0x8000) is the "extended language tag" flag; leaving it 0 with
        // the low 15 bits = 0x7fff doesn't resolve to a valid ISO 639-2/T
        // packed code, but it's what both reference encoders write so we
        // mirror byte-for-byte.
        b.append(contentsOf: [0x7f, 0xff, 0x00, 0x00])      // language + pre_defined
        return b
    }

    /// hdlr inside mdia (37-byte body) — "VideoHandler".
    private func hdlrMdiaBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: ascii("mhlr"))                 // pre_defined / component_type
        b.append(contentsOf: ascii("vide"))                 // handler_type
        b.append(contentsOf: [UInt8](repeating: 0, count: 12))  // 3× reserved uint32
        b.append(0x0c)                                      // pascal-string length
        b.append(contentsOf: ascii("VideoHandler"))         // 12 chars
        return b
    }

    /// minf body = vmhd + hdlr (data) + dinf + stbl.
    private func minfBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "vmhd", body: vmhdBody())
        appendAtom(into: &b, type: "hdlr", body: hdlrMinfBody())
        appendAtom(into: &b, type: "dinf", body: dinfBody())
        appendAtom(into: &b, type: "stbl", body: stblBody())
        return b
    }

    private func vmhdBody() -> Data {
        var b = Data()
        b.append(contentsOf: [0x00, 0x00, 0x00, 0x01])      // version+flags (flag bit = 1)
        b.append(contentsOf: [UInt8](repeating: 0, count: 8))   // graphicsmode + opcolor[3]
        return b
    }

    private func hdlrMinfBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: ascii("dhlr"))                 // pre_defined / component_type
        b.append(contentsOf: ascii("url "))                 // handler_type
        b.append(contentsOf: [UInt8](repeating: 0, count: 12))  // 3× reserved
        b.append(0x0b)                                      // pascal length
        b.append(contentsOf: ascii("DataHandler"))          // 11 chars
        return b
    }

    private func dinfBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "dref", body: drefBody())
        return b
    }

    private func drefBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(1))                  // entry_count
        // Inner entry: 12-byte 'url ' atom with self-contained flag.
        var entry = Data()
        entry.append(contentsOf: beBytes32(12))             // size
        entry.append(contentsOf: ascii("url "))
        entry.append(contentsOf: beBytes32(0x00000001))     // flags (self_contained)
        b.append(entry)
        return b
    }

    /// stbl body = stsd → stts → stsc → stsz → stco. Order is spec-mandated.
    private func stblBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "stsd", body: stsdBody())
        appendAtom(into: &b, type: "stts", body: sttsBody())
        appendAtom(into: &b, type: "stsc", body: stscBody())
        appendAtom(into: &b, type: "stsz", body: stszBody())
        appendAtom(into: &b, type: "stco", body: stcoBody())
        return b
    }

    /// stsd: 1 entry, visual sample description for `codecFourCC`.
    /// Mimics Alley's 94-byte body shape (no fiel/pasp/encoder-name).
    /// compressor_name field is left empty (length=0, zero-padded).
    /// Per Pass A invariant for DXV3; HAP variants use the same shape
    /// with their own FourCC.
    private func stsdBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(1))                  // entry_count
        // Sample entry — 86-byte atom (= 8 hdr + 78 body)
        var entry = Data()
        entry.append(contentsOf: beBytes32(86))             // size
        entry.append(contentsOf: ascii(codecFourCC))        // sample format
        entry.append(contentsOf: [UInt8](repeating: 0, count: 6))   // reserved (6 bytes)
        entry.append(contentsOf: beBytes16(1))              // data_reference_index
        // QuickTime VisualSampleEntry tail (78 bytes total inside the entry):
        entry.append(contentsOf: beBytes16(0))              // version
        entry.append(contentsOf: beBytes16(0))              // revision_level
        entry.append(contentsOf: ascii("FFMP"))             // vendor
        entry.append(contentsOf: beBytes32(0x00000200))     // temporal_quality = 512
        entry.append(contentsOf: beBytes32(0x00000200))     // spatial_quality = 512
        entry.append(contentsOf: beBytes16(presentationWidth))
        entry.append(contentsOf: beBytes16(presentationHeight))
        entry.append(contentsOf: beBytes32(0x00480000))     // horiz_res = 72.0 (16.16)
        entry.append(contentsOf: beBytes32(0x00480000))     // vert_res
        entry.append(contentsOf: beBytes32(0))              // data_size
        entry.append(contentsOf: beBytes16(1))              // frame_count
        entry.append(contentsOf: [UInt8](repeating: 0, count: 32))  // compressor_name (length=0 + 31 zero pad)
        entry.append(contentsOf: beBytes16(24))             // depth
        entry.append(contentsOf: [0xff, 0xff])              // color_table_id = -1
        b.append(entry)
        return b
    }

    /// stts: one entry covering all samples uniformly at sampleDelta.
    private func sttsBody() -> Data {
        let frameCount = UInt32(sampleSizes.count)
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(1))                  // entry_count
        b.append(contentsOf: beBytes32(frameCount))         // sample_count
        b.append(contentsOf: beBytes32(sampleDelta))        // sample_delta
        return b
    }

    /// stsc: one entry, samples_per_chunk = 1 (Alley shape). Combined
    /// with the per-sample stco below, this declares "every sample is
    /// its own chunk." Phase 7A Finding 6.
    private func stscBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(1))                  // entry_count
        b.append(contentsOf: beBytes32(1))                  // first_chunk
        b.append(contentsOf: beBytes32(1))                  // samples_per_chunk
        b.append(contentsOf: beBytes32(1))                  // sample_description_index
        return b
    }

    /// stsz: variable per-sample sizes.
    private func stszBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(0))                  // sample_size = 0 (variable)
        b.append(contentsOf: beBytes32(UInt32(sampleSizes.count)))  // sample_count
        for s in sampleSizes {
            b.append(contentsOf: beBytes32(s))
        }
        return b
    }

    /// stco: one chunk offset per sample (Phase 7A Finding 6 — Alley shape).
    /// Each sample is its own chunk per stsc above; chunk N's offset is
    /// firstChunkOffset + sum(sampleSizes[0..<N]).
    private func stcoBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(UInt32(sampleSizes.count)))  // entry_count
        var running = firstChunkOffset
        for size in sampleSizes {
            // mdat must fit in 32-bit offsets (enforced at finish() — see
            // the mdatExceeds4GB guard). Cast is safe under that guard.
            b.append(contentsOf: beBytes32(UInt32(running)))
            running += UInt64(size)
        }
        return b
    }

    /// udta with a single ©swr atom = writer identity string.
    private func udtaBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "©swr", body: copyrightSwrBody())
        return b
    }

    private func copyrightSwrBody() -> Data {
        // QuickTime user-data string atom layout: 2-byte length + 2-byte
        // language + content bytes. Language 0x55c4 = "und".
        let str = Array(writerVersion.utf8)
        precondition(str.count <= Int(UInt16.max))
        var b = Data()
        b.append(contentsOf: beBytes16(UInt16(str.count)))
        b.append(contentsOf: [0x55, 0xc4])                  // language
        b.append(contentsOf: str)
        return b
    }

    // MARK: - Phase 4 audio trak (LPCM in32, matches the Alley reference)

    private var audioFrameCount: UInt32 {
        guard let info = audioInfo, info.bytesPerFrame > 0 else { return 0 }
        return UInt32(audioPCM.count / info.bytesPerFrame)
    }

    /// audio trak body = tkhd + edts/elst + mdia (track_id 2).
    private func audioTrakBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "tkhd", body: audioTkhdBody())
        appendAtom(into: &b, type: "edts", body: audioEdtsBody())
        appendAtom(into: &b, type: "mdia", body: audioMdiaBody())
        return b
    }

    private func audioTkhdBody() -> Data {
        let durMS = audioDurationMS
        var b = Data()
        b.append(contentsOf: beBytes32(0x00000003))         // version+flags (enabled+in-movie)
        b.append(contentsOf: beBytes32(0))                  // creation
        b.append(contentsOf: beBytes32(0))                  // modification
        b.append(contentsOf: beBytes32(2))                  // track_id = 2
        b.append(contentsOf: beBytes32(0))                  // reserved
        b.append(contentsOf: beBytes32(UInt32(durMS)))      // duration (movie ts)
        b.append(contentsOf: [UInt8](repeating: 0, count: 8))   // reserved
        b.append(contentsOf: beBytes16(0))                  // layer
        b.append(contentsOf: beBytes16(0))                  // alternate_group
        b.append(contentsOf: beBytes16(0x0100))             // volume = 1.0 (audio)
        b.append(contentsOf: beBytes16(0))                  // reserved
        b.append(contentsOf: identityMatrix())              // 36 bytes
        b.append(contentsOf: beBytes32(0))                  // width = 0 (audio)
        b.append(contentsOf: beBytes32(0))                  // height = 0
        return b
    }

    private func audioEdtsBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "elst", body: audioElstBody())
        return b
    }

    private func audioElstBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(1))                  // entry_count
        b.append(contentsOf: beBytes32(UInt32(audioDurationMS)))  // segment_duration
        b.append(contentsOf: beBytes32(0))                  // media_time
        b.append(contentsOf: beBytes32(0x00010000))         // media_rate = 1.0
        return b
    }

    private func audioMdiaBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "mdhd", body: audioMdhdBody())
        appendAtom(into: &b, type: "hdlr", body: audioHdlrMdiaBody())
        appendAtom(into: &b, type: "minf", body: audioMinfBody())
        return b
    }

    /// audio mdhd — timescale = sample rate, duration = frame count.
    private func audioMdhdBody() -> Data {
        let rate = UInt32(audioInfo?.sampleRate ?? 48000)
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes32(0))                  // creation
        b.append(contentsOf: beBytes32(0))                  // modification
        b.append(contentsOf: beBytes32(rate))               // timescale = sample rate
        b.append(contentsOf: beBytes32(audioFrameCount))    // duration (frames)
        b.append(contentsOf: [0x7f, 0xff, 0x00, 0x00])      // language + pre_defined (matches ref)
        return b
    }

    /// hdlr (soun) — "SoundHandler" (mirrors the video hdlr shape).
    private func audioHdlrMdiaBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: ascii("mhlr"))                 // component_type
        b.append(contentsOf: ascii("soun"))                 // handler_type
        b.append(contentsOf: [UInt8](repeating: 0, count: 12))  // 3× reserved
        b.append(0x0c)                                      // pascal length = 12
        b.append(contentsOf: ascii("SoundHandler"))         // 12 chars
        return b
    }

    /// audio minf = smhd + hdlr(data) + dinf + stbl.
    private func audioMinfBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "smhd", body: smhdBody())
        appendAtom(into: &b, type: "hdlr", body: hdlrMinfBody())   // reuse video's "DataHandler" url
        appendAtom(into: &b, type: "dinf", body: dinfBody())       // reuse video's dref
        appendAtom(into: &b, type: "stbl", body: audioStblBody())
        return b
    }

    private func smhdBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))                  // version+flags
        b.append(contentsOf: beBytes16(0))                  // balance
        b.append(contentsOf: beBytes16(0))                  // reserved
        return b
    }

    private func audioStblBody() -> Data {
        var b = Data()
        appendAtom(into: &b, type: "stsd", body: audioStsdBody())
        appendAtom(into: &b, type: "stts", body: audioSttsBody())
        appendAtom(into: &b, type: "stsc", body: audioStscBody())
        appendAtom(into: &b, type: "stsz", body: audioStszBody())
        appendAtom(into: &b, type: "stco", body: audioStcoBody())
        return b
    }

    /// audio stsd. SoundDescription V1 (`in32` + `wave`{frma,enda} + `chan`)
    /// for rates ≤ 65535 — byte-identical to the Alley reference at 48 kHz.
    /// The V1 sample-rate field is 16.16 fixed-point and CANNOT represent
    /// rates ≥ 65536 (88.2/96 kHz overflowed → garbage rate → slow/artifact
    /// playback), so those use SoundDescription V2 (`lpcm`, Float64 rate) —
    /// the same layout AVAssetWriter emits for high-rate LPCM.
    private func audioStsdBody() -> Data {
        let info = audioInfo!
        var b = Data()
        b.append(contentsOf: beBytes32(0))               // version+flags
        b.append(contentsOf: beBytes32(1))               // entry_count
        if info.sampleRate > 65535 {
            b.append(audioSampleEntryV2(info))
        } else {
            b.append(audioSampleEntryV1(info))
        }
        return b
    }

    /// SoundDescription V2 LPCM sample entry (Float64 rate) — for rates the
    /// 16.16 V1 field can't hold (88.2/96 kHz). Mirrors AVAssetWriter's
    /// layout. `formatSpecificFlags` 0x0C = signed integer + packed,
    /// little-endian (no big-endian bit).
    private func audioSampleEntryV2(_ info: AudioStreamInfo) -> Data {
        let channels = UInt32(max(1, info.channels))
        let bytesPerFrame = channels * UInt32(info.bitsPerChannel / 8)
        var body = Data()
        body.append(contentsOf: [UInt8](repeating: 0, count: 6))   // reserved
        body.append(contentsOf: beBytes16(1))            // data_reference_index
        body.append(contentsOf: beBytes16(2))            // version = 2
        body.append(contentsOf: beBytes16(0))            // revision
        body.append(contentsOf: beBytes32(0))            // vendor
        body.append(contentsOf: beBytes16(3))            // always3
        body.append(contentsOf: beBytes16(16))           // always16
        body.append(contentsOf: [0xff, 0xfe])            // alwaysMinus2
        body.append(contentsOf: beBytes16(0))            // always0
        body.append(contentsOf: beBytes32(0x0001_0000))  // always65536
        body.append(contentsOf: beBytes32(72))           // sizeOfStructOnly (entry size, no extensions)
        // audioSampleRate — Float64, big-endian
        body.append(contentsOf: withUnsafeBytes(of: Double(info.sampleRate).bitPattern.bigEndian) { Array($0) })
        body.append(contentsOf: beBytes32(channels))     // numAudioChannels
        body.append(contentsOf: beBytes32(0x7f00_0000))  // always7F000000
        body.append(contentsOf: beBytes32(UInt32(info.bitsPerChannel)))  // constBitsPerChannel
        body.append(contentsOf: beBytes32(0x0000_000c))  // formatSpecificFlags = signed+packed LE
        body.append(contentsOf: beBytes32(bytesPerFrame))// constBytesPerAudioPacket
        body.append(contentsOf: beBytes32(1))            // constLPCMFramesPerAudioPacket
        var entry = Data()
        entry.append(contentsOf: beBytes32(UInt32(8 + body.count)))  // size
        entry.append(contentsOf: ascii("lpcm"))
        entry.append(body)
        return entry
    }

    /// SoundDescription V1 `in32` sample entry — byte-identical to the
    /// Alley reference for a stereo source; channels pass-through for
    /// mono/multichannel (chan layout tag adapts). Rates ≤ 65535 only.
    private func audioSampleEntryV1(_ info: AudioStreamInfo) -> Data {
        let channels = UInt16(max(1, info.channels))
        let rate = UInt32(info.sampleRate)
        let bytesPerChannel = UInt32(info.bitsPerChannel / 8)        // 4 (32-bit)
        let bytesPerFrame = UInt32(info.channels) * bytesPerChannel  // ch×4

        // --- inner wave atom: frma + enda(little-endian=1) + terminator
        var wave = Data()
        do {
            var frma = Data(); frma.append(contentsOf: ascii("in32"))
            var w = Data()
            wrapAtom(into: &w, type: "frma", body: frma)            // 12
            var enda = Data(); enda.append(contentsOf: beBytes16(1)) // 1 = little-endian
            wrapAtom(into: &w, type: "enda", body: enda)            // 10
            w.append(contentsOf: beBytes32(8))                      // terminator atom (size 8, type 0)
            w.append(contentsOf: beBytes32(0))
            wave = w
        }
        // --- chan atom (channel layout)
        let layoutTag: UInt32
        switch info.channels {
        case 1:  layoutTag = 0x0064_0001   // Mono
        case 2:  layoutTag = 0x0065_0002   // Stereo
        default: layoutTag = 0x0093_0000 | UInt32(info.channels & 0xffff)  // DiscreteInOrder | n
        }
        var chan = Data()
        chan.append(contentsOf: beBytes32(0))            // version+flags
        chan.append(contentsOf: beBytes32(layoutTag))    // mChannelLayoutTag
        chan.append(contentsOf: beBytes32(0))            // mChannelBitmap
        chan.append(contentsOf: beBytes32(0))            // mNumberChannelDescriptions

        // --- AudioSampleEntry body (in32, SoundDescription V1). The
        // 'in32' format code + size are added by the wrapper below; the
        // body starts at the 6-byte reserved field.
        var entry = Data()
        entry.append(contentsOf: [UInt8](repeating: 0, count: 6))  // reserved
        entry.append(contentsOf: beBytes16(1))           // data_reference_index
        entry.append(contentsOf: beBytes16(1))           // version = 1
        entry.append(contentsOf: beBytes16(0))           // revision
        entry.append(contentsOf: beBytes32(0))           // vendor
        entry.append(contentsOf: beBytes16(channels))    // channels
        entry.append(contentsOf: beBytes16(16))          // sample size (legacy constant)
        entry.append(contentsOf: beBytes16(0))           // compression_id
        entry.append(contentsOf: beBytes16(0))           // packet_size
        entry.append(contentsOf: beBytes32(rate << 16))  // sample_rate (16.16 fixed)
        // SoundDescription V1 fields:
        entry.append(contentsOf: beBytes32(1))           // samples_per_packet
        entry.append(contentsOf: beBytes32(bytesPerChannel))  // bytes_per_packet
        entry.append(contentsOf: beBytes32(bytesPerFrame))    // bytes_per_frame
        entry.append(contentsOf: beBytes32(2))           // bytes_per_sample (legacy constant)
        // Extensions:
        appendAtom(into: &entry, type: "wave", body: wave)
        appendAtom(into: &entry, type: "chan", body: chan)

        // Wrap the entry body with its size + 'in32' format code.
        var wrapped = Data()
        wrapped.append(contentsOf: beBytes32(UInt32(8 + entry.count)))
        wrapped.append(contentsOf: ascii("in32"))
        wrapped.append(entry)
        return wrapped
    }

    /// audio stts: one entry, all frames at delta 1 (timescale = rate).
    private func audioSttsBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))               // version+flags
        b.append(contentsOf: beBytes32(1))               // entry_count
        b.append(contentsOf: beBytes32(audioFrameCount)) // sample_count
        b.append(contentsOf: beBytes32(1))               // sample_delta
        return b
    }

    /// audio stsc: one chunk holding all frames.
    private func audioStscBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))               // version+flags
        b.append(contentsOf: beBytes32(1))               // entry_count
        b.append(contentsOf: beBytes32(1))               // first_chunk
        b.append(contentsOf: beBytes32(audioFrameCount)) // samples_per_chunk
        b.append(contentsOf: beBytes32(1))               // sample_description_index
        return b
    }

    /// audio stsz: constant per-sample size = bytes per interleaved frame.
    private func audioStszBody() -> Data {
        let info = audioInfo!
        var b = Data()
        b.append(contentsOf: beBytes32(0))               // version+flags
        b.append(contentsOf: beBytes32(UInt32(info.bytesPerFrame)))  // sample_size (constant)
        b.append(contentsOf: beBytes32(audioFrameCount)) // sample_count
        return b
    }

    /// audio stco: single chunk at the audio region's mdat offset.
    private func audioStcoBody() -> Data {
        var b = Data()
        b.append(contentsOf: beBytes32(0))               // version+flags
        b.append(contentsOf: beBytes32(1))               // entry_count
        b.append(contentsOf: beBytes32(UInt32(audioChunkOffset)))
        return b
    }

    // MARK: - Atom layout helpers

    /// Append the bytes `[size BE32, type bytes, body...]` to `dst`.
    private func appendAtom(into dst: inout Data, type: String, body: Data) {
        wrapAtom(into: &dst, type: type, body: body)
    }

    private func wrapAtom(into dst: inout Data, type: String, body: Data) {
        let typeBytes = Array(type.utf8)
        // QuickTime atom types are 4 bytes. Most are ASCII; ©swr uses a
        // single non-ASCII byte (0xa9) so we need to honor caller intent
        // by inspecting the original character set.
        let typeRaw: [UInt8]
        if type == "©swr" {
            typeRaw = [0xa9, 0x73, 0x77, 0x72]
        } else {
            precondition(typeBytes.count == 4, "Atom type must be 4 bytes: \(type)")
            typeRaw = typeBytes
        }
        let total = UInt32(8 + body.count)
        dst.append(contentsOf: beBytes32(total))
        dst.append(contentsOf: typeRaw)
        dst.append(body)
    }

    /// Standard 3×3 video transform matrix: identity in 16.16/2.30 mixed form.
    /// Order: a, b, u, c, d, v, x, y, w. Per QuickTime: [1 0 0; 0 1 0; 0 0 1]
    /// stored as 9 entries with the bottom row in 2.30 fixed (= 0x40000000
    /// for 1.0).
    private func identityMatrix() -> [UInt8] {
        var m = [UInt8]()
        for v in [
            UInt32(0x00010000), UInt32(0), UInt32(0),
            UInt32(0), UInt32(0x00010000), UInt32(0),
            UInt32(0), UInt32(0), UInt32(0x40000000),
        ] {
            m.append(contentsOf: beBytes32(v))
        }
        return m
    }
}

// MARK: - Endian / ascii helpers

@inline(__always)
private func beBytes32(_ v: UInt32) -> [UInt8] {
    return [
        UInt8((v >> 24) & 0xff),
        UInt8((v >> 16) & 0xff),
        UInt8((v >> 8)  & 0xff),
        UInt8( v        & 0xff),
    ]
}

@inline(__always)
private func beBytes16(_ v: UInt16) -> [UInt8] {
    return [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
}

@inline(__always)
private func ascii(_ s: String) -> [UInt8] {
    return Array(s.utf8)
}

/// v0.9.1 Phase C — backward-compatibility typealias. Every existing
/// call site (EncodeQueue, EncodePipeline, ~8 test files) referencing
/// `DXVMOVWriter` continues to resolve to the same concrete class.
/// Default `codecFourCC: "DXD3"` on `VariantMOVWriter.init` preserves
/// byte-identity for DXV3 callers. HAP encoders (Phase D-F) construct
/// `VariantMOVWriter` directly with their own FourCC.
public typealias DXVMOVWriter = VariantMOVWriter
