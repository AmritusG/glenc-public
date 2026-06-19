/*
 * MalformedDXVFixtures.swift — GlEnc pre-v1.0.0 malformed-input fuzz corpus.
 *
 * This is the START of the permanent fuzz corpus seeded by Hardening
 * Fix-Brief 1 (source-input validation at the reader trust boundary).
 *
 * Threat model: a VJ drops a malformed/adversarial source file into GlEnc
 * during a live gig. The goal of the corpus is to prove that every such
 * file is converted into a clean thrown `SourceReaderError` at the reader
 * entry — never a crash, never a precondition trap, never wrong-but-
 * successful output.
 *
 * Why a generator instead of committed binaries
 * ──────────────────────────────────────────────
 * Each malformed DXV variant is derived deterministically from the
 * already-committed real reference `reference/dxt1/ffmpeg.mov` by
 * hex-patching its geometry atoms in memory and writing the result to a
 * throwaway temp file the test feeds to the reader. Committing 3 × ~2.3 MB
 * near-duplicate `.mov` files would bloat the repo for no gain — the
 * reference is already committed and the patch is reproducible. Future
 * fixtures (truncated mdat, lying HAP header, etc.) extend `Mutation`.
 *
 * Atom layout (verified against reference/dxt1/ffmpeg.mov):
 *   - tkhd (version 0): the track display dimensions are 16.16 fixed-point.
 *     Width integer-part at (tkhd-tag-offset + 80), height at + 84. The
 *     reference holds 1920 (0x0780_0000) and 1080 (0x0438_0000).
 *   - stsd VisualSampleEntry: width/height are UInt16 at
 *     (stsd-tag-offset + 44) and (+ 46) — 1920 / 1080 in the reference.
 *     DXVDemuxer prefers the stsd dimensions; we patch BOTH atoms
 *     consistently so the demuxed geometry matches regardless of which
 *     the demuxer reads.
 *
 * The atom tags are located by their LAST occurrence in the file: the
 * real moov atoms sit after the large mdat body, so a backward search
 * avoids matching a coincidental "tkhd"/"stsd" byte sequence inside the
 * compressed DXV mdat payload.
 */

import Foundation

enum MalformedDXVFixtures {

    /// A named, deterministic mutation applied to the reference DXV.
    ///
    /// Where each `.dimensions` mutation now fails (Fix-Brief 1-narrow —
    /// the blanket source min-4 was narrowed to "positive", with the
    /// sub-4-height crash guarded at the DXV DXT decode site):
    ///   - `0×0`            → rejected at `DxvSourceReader.init`
    ///                        (`validateSourceGeometry`, non-positive).
    ///   - `65535×65535`    → rejected at init (`sourceFrameTooLarge`).
    ///   - `1920×2` (h < 4) → init SUCCEEDS; rejected on the first
    ///                        `readNextFrame` (zero-block DXT guard →
    ///                        `dxvZeroBlockGeometry`, wrapped as
    ///                        `dxvDecodeFailed`).
    ///   - non-4-aligned / sub-4-width-with-adequate-height → accepted
    ///     (the validated-fine cases — geometry guard passes).
    enum Mutation: CustomStringConvertible {
        /// Overwrite both the tkhd and stsd display dimensions. UInt16
        /// fields, so values are clamped to [0, 65535] on write — the
        /// realistic range a DXV container can actually carry.
        case dimensions(width: Int, height: Int)

        var description: String {
            switch self {
            case .dimensions(let w, let h): return "dimensions(\(w)x\(h))"
            }
        }
    }

    enum FixtureError: Error, CustomStringConvertible {
        case referenceMissing(URL)
        case atomNotFound(String)
        var description: String {
            switch self {
            case .referenceMissing(let u): return "fuzz-corpus reference DXV missing: \(u.path)"
            case .atomNotFound(let t): return "fuzz-corpus: atom '\(t)' not found in reference DXV"
            }
        }
    }

    /// The committed real reference DXV this corpus patches from.
    /// `#file` here is `<repo>/Tests/GlEncTests/FuzzCorpus/MalformedDXVFixtures.swift`
    /// → four `deletingLastPathComponent()` calls reach the repo root.
    static var referenceURL: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()   // FuzzCorpus
            .deletingLastPathComponent()   // GlEncTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("reference/dxt1/ffmpeg.mov")
    }

    /// Materialize a malformed variant into `dest` (a throwaway temp URL).
    static func make(_ mutation: Mutation, into dest: URL) throws {
        let ref = referenceURL
        guard FileManager.default.fileExists(atPath: ref.path) else {
            throw FixtureError.referenceMissing(ref)
        }
        var data = try Data(contentsOf: ref)
        switch mutation {
        case .dimensions(let w, let h):
            try patchDimensions(&data, width: w, height: h)
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try data.write(to: dest)
    }

    // MARK: - Patching internals

    private static func patchDimensions(_ data: inout Data, width: Int, height: Int) throws {
        let w16 = UInt16(clamping: max(0, width))
        let h16 = UInt16(clamping: max(0, height))
        let bytes = [UInt8](data)

        guard let stsd = lastIndex(of: "stsd", in: bytes) else {
            throw FixtureError.atomNotFound("stsd")
        }
        writeBE16(&data, at: stsd + 44, w16)   // VisualSampleEntry width
        writeBE16(&data, at: stsd + 46, h16)   // VisualSampleEntry height

        guard let tkhd = lastIndex(of: "tkhd", in: bytes) else {
            throw FixtureError.atomNotFound("tkhd")
        }
        writeBE16(&data, at: tkhd + 80, w16)   // tkhd width — 16.16 integer part
        writeBE16(&data, at: tkhd + 82, 0)     // tkhd width — fraction
        writeBE16(&data, at: tkhd + 84, h16)   // tkhd height — 16.16 integer part
        writeBE16(&data, at: tkhd + 86, 0)     // tkhd height — fraction
    }

    private static func writeBE16(_ data: inout Data, at offset: Int, _ value: UInt16) {
        data[offset] = UInt8(value >> 8)
        data[offset + 1] = UInt8(value & 0xFF)
    }

    /// Last occurrence of a 4-char atom tag — the genuine moov atoms sit
    /// after the mdat body, so searching backward avoids mdat-payload
    /// false positives.
    private static func lastIndex(of tag: String, in bytes: [UInt8]) -> Int? {
        let needle = Array(tag.utf8)
        guard bytes.count >= needle.count else { return nil }
        var i = bytes.count - needle.count
        while i >= 0 {
            var match = true
            for j in 0..<needle.count where bytes[i + j] != needle[j] {
                match = false
                break
            }
            if match { return i }
            i -= 1
        }
        return nil
    }
}
