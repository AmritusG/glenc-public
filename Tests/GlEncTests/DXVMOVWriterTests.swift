/*
 * DXVMOVWriter atom-by-atom diffs against the Pass A reference corpus.
 *
 * The strategy is structural rather than file-level byte-equal: encoder
 * discretion (chunking, encoder identity in udta, FFmpeg's stsd extension
 * atoms) means GlEnc's output won't be a bit-for-bit match against any
 * reference. What MUST hold is per Pass A FINDINGS.md:
 *
 *   spec-mandated: ftyp body, mvhd body, tkhd body, edts/elst body,
 *                  mdhd body, mdia hdlr body, vmhd body, minf hdlr body,
 *                  dinf/dref body, stsd substantive 78-byte sample entry
 *                  body (DXD3 + FFMP + 1920×1080 + 72dpi + depth=24),
 *                  stbl skeleton order (stsd → stts → stsc → stsz → stco),
 *                  stts body for uniform 30fps,
 *                  every per-frame DXV3 packet's bytes,
 *                  stream-level codec FourCC = DXD3 throughout.
 *
 *   discretion:    moov placement (we pick end-of-file, matches Alley),
 *                  stsd extension atoms (we omit fiel/pasp/encoder-name,
 *                  matches Alley), udta payload (we write
 *                  "GlEnc <version>" in ©swr), stsc/stco chunking (we use
 *                  one chunk).
 *
 * The tests classify each atom as MATCH (spec-mandated) or DIFFER
 * (discretion-allowed) and fail if any spec-mandated atom diverges.
 */

import XCTest
import Foundation
import CoreMedia
@testable import GlEncCore

final class DXVMOVWriterTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/dxt1")
    }()

    // MARK: - Full pipeline: 30 PNGs → DXT1Encoder → DXVMOVWriter → temp .mov

    private func encodePNGsToTempMOV() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("glenc-test-\(UUID().uuidString).mov")

        let enc = DXT1Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: false)
        let writer = try DXVMOVWriter(
            destURL: tmp,
            format: .dxt1,
            presentationWidth: 1920,
            presentationHeight: 1080,
            fps: 30,
            writerVersion: "GlEnc 0.2.0")

        for i in 0..<30 {
            let pngURL = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            let frame = try DXT1EncoderTests_PNGLoader.loadPNGAsBGRAPixelFrame(
                url: pngURL, width: 1920, height: 1080)
            let pkt = try enc.encode(frame: frame)
            // PTS in mvhd timescale: 1000 ticks per second, 1/30s per frame.
            let pts = CMTime(value: Int64(i) * 1000 / 30, timescale: 1000)
            try writer.append(packet: pkt, presentationTime: pts)
        }
        try enc.finish()
        try writer.finish()
        return tmp
    }

    // MARK: - Tests

    func testWriterProducesValidMOV() throws {
        let url = try encodePNGsToTempMOV()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)

        // Top-level atoms in order: ftyp, wide, mdat, moov.
        let topLevel = AtomTree(data: data, range: 0..<data.count)
        let kinds = topLevel.children.map { $0.type }
        XCTAssertEqual(kinds, ["ftyp", "wide", "mdat", "moov"],
                       "top-level layout mismatch")
    }

    func testStructuralDiff_vs_ffmpeg() throws {
        let ourURL = try encodePNGsToTempMOV()
        defer { try? FileManager.default.removeItem(at: ourURL) }
        let our = try Data(contentsOf: ourURL)
        let theirs = try Data(contentsOf: Self.referenceDir.appendingPathComponent("ffmpeg.mov"))

        let report = compareMOVs(label: "vs ffmpeg.mov", our: our, theirs: theirs)
        print(report.summary)
        XCTAssertTrue(report.specMandatedDiffs.isEmpty,
                      "spec-mandated atom divergence vs ffmpeg.mov:\n\(report.specMandatedDiffs.joined(separator: "\n"))")
    }

    func testStructuralDiff_vs_alley() throws {
        let ourURL = try encodePNGsToTempMOV()
        defer { try? FileManager.default.removeItem(at: ourURL) }
        let our = try Data(contentsOf: ourURL)
        let theirs = try Data(contentsOf: Self.referenceDir.appendingPathComponent("alley.mov"))

        let report = compareMOVs(label: "vs alley.mov", our: our, theirs: theirs)
        print(report.summary)
        XCTAssertTrue(report.specMandatedDiffs.isEmpty,
                      "spec-mandated atom divergence vs alley.mov:\n\(report.specMandatedDiffs.joined(separator: "\n"))")
    }

    /// The 78-byte VisualSampleEntry inside stsd carries the spec-mandated
    /// substantive fields (FourCC DXD3, vendor FFMP, dimensions 1920×1080,
    /// 72 DPI, depth 24, color_table_id 0xFFFF). Pass A FINDINGS.md notes
    /// the first 78 bytes of the entry body are byte-identical between
    /// Alley and AME — strong spec-mandate. Verify ours matches.
    func testStsdSubstantiveFieldsMatch() throws {
        let ourURL = try encodePNGsToTempMOV()
        defer { try? FileManager.default.removeItem(at: ourURL) }
        let our = try Data(contentsOf: ourURL)
        let theirs = try Data(contentsOf: Self.referenceDir.appendingPathComponent("alley.mov"))

        // Find stsd in each, then the first sample entry's 78-byte tail
        // (after the 8-byte atom header).
        let oursStsd = try findStsdSampleEntryBody(our)
        let theirsStsd = try findStsdSampleEntryBody(theirs)
        XCTAssertEqual(oursStsd.count, 78, "ours stsd entry body wrong size")
        XCTAssertEqual(theirsStsd.count, 78, "alley stsd entry body wrong size")
        XCTAssertEqual(oursStsd, theirsStsd,
                       "stsd VisualSampleEntry substantive fields diverge from Alley (spec-mandated per Pass A)")
    }

    private func findStsdSampleEntryBody(_ data: Data) throws -> Data {
        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let moov = tree.children.first(where: { $0.type == "moov" }),
              let trak = moov.children.first(where: { $0.type == "trak" }),
              let mdia = trak.children.first(where: { $0.type == "mdia" }),
              let minf = mdia.children.first(where: { $0.type == "minf" }),
              let stbl = minf.children.first(where: { $0.type == "stbl" }),
              let stsd = stbl.children.first(where: { $0.type == "stsd" })
        else { throw NSError(domain: "MOV", code: 1, userInfo: [NSLocalizedDescriptionKey: "stsd not found"]) }
        // stsd has children = sample entries (parsed by AtomTree). First entry
        // is the DXD3 visual sample entry; its first 78 bytes after the 8-byte
        // header are the substantive QuickTime VisualSampleEntry fields.
        guard let entry = stsd.children.first(where: { $0.type == "DXD3" }) else {
            throw NSError(domain: "MOV", code: 2, userInfo: [NSLocalizedDescriptionKey: "DXD3 entry not in stsd"])
        }
        let body = entry.bodyRange
        return data.subdata(in: body.lowerBound..<(body.lowerBound + 78))
    }

    func testFrameByteEquality_postWriter() throws {
        // Per Pass A: DXV3 frame headers + payloads must be byte-identical to
        // ffmpeg.mov's. Verifies the writer doesn't accidentally munge the
        // packet bytes the encoder produced.
        let ourURL = try encodePNGsToTempMOV()
        defer { try? FileManager.default.removeItem(at: ourURL) }

        let ourExtractor = try MOVFrameExtractor(url: ourURL)
        let theirsExtractor = try MOVFrameExtractor(
            url: Self.referenceDir.appendingPathComponent("ffmpeg.mov"))
        XCTAssertEqual(ourExtractor.frameCount, 30)
        XCTAssertEqual(theirsExtractor.frameCount, 30)

        for i in 0..<30 {
            let ours = ourExtractor.frameData(at: i)
            let theirs = theirsExtractor.frameData(at: i)
            XCTAssertEqual(ours, theirs,
                           "frame \(i) bytes diverge through DXVMOVWriter")
        }
    }

    /// v0.9.1 Phase C — proves the rename from DXVMOVWriter to
    /// VariantMOVWriter + the new `codecFourCC` parameter route
    /// correctly into the stsd sample entry. Constructs the writer
    /// with `codecFourCC: "Hap1"`, writes a single dummy frame, and
    /// asserts the resulting file's stsd contains a "Hap1" entry
    /// (rather than the default "DXD3"). This is a smoke test for
    /// the parameter plumbing — actual HAP encoding (Snappy + section
    /// header + real DXT payload) lands in Phase D.
    func testHap1FourCCRoutesThroughStsd() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-phaseC-hap1-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Construct via the new direct-API path (NOT the typealias)
        // so we exercise the new parameter explicitly.
        let writer = try VariantMOVWriter(
            destURL: tmp,
            format: .dxt1,
            presentationWidth: 1920,
            presentationHeight: 1080,
            fps: 30,
            writerVersion: "GlEnc 0.9.1 Phase C smoke",
            codecFourCC: "Hap1")
        // 16 bytes of placeholder payload — not a real Hap1 section
        // header, just enough to give the writer a sample to record.
        try writer.append(packet: Data(repeating: 0xAB, count: 16),
                          presentationTime: .zero)
        try writer.finish()

        let bytes = try Data(contentsOf: tmp)
        let tree = AtomTree(data: bytes, range: 0..<bytes.count)
        guard let moov = tree.children.first(where: { $0.type == "moov" }),
              let trak = moov.children.first(where: { $0.type == "trak" }),
              let mdia = trak.children.first(where: { $0.type == "mdia" }),
              let minf = mdia.children.first(where: { $0.type == "minf" }),
              let stbl = minf.children.first(where: { $0.type == "stbl" }),
              let stsd = stbl.children.first(where: { $0.type == "stsd" })
        else {
            XCTFail("stsd not found in Hap1 file")
            return
        }
        XCTAssertNotNil(stsd.children.first(where: { $0.type == "Hap1" }),
                        "Hap1 sample entry missing — codecFourCC param did not route through to stsd")
        XCTAssertNil(stsd.children.first(where: { $0.type == "DXD3" }),
                     "DXD3 entry should NOT appear when codecFourCC=\"Hap1\"")
    }

    /// Sanity: invalid codecFourCC (wrong length or non-ASCII) throws.
    /// Catches typos that would otherwise silently produce a malformed
    /// stsd.
    func testInvalidCodecFourCCThrows() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-phaseC-invalid-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertThrowsError(try VariantMOVWriter(
            destURL: tmp, format: .dxt1,
            presentationWidth: 100, presentationHeight: 100, fps: 30,
            codecFourCC: "TooLong"))
        XCTAssertThrowsError(try VariantMOVWriter(
            destURL: tmp, format: .dxt1,
            presentationWidth: 100, presentationHeight: 100, fps: 30,
            codecFourCC: "abc"))   // 3 bytes
        XCTAssertThrowsError(try VariantMOVWriter(
            destURL: tmp, format: .dxt1,
            presentationWidth: 100, presentationHeight: 100, fps: 30,
            codecFourCC: "Hap€"))  // non-ASCII (Euro sign is multi-byte UTF-8)
    }

    // MARK: - v0.9.2 Phase D.5 — writer-version round-trip

    /// The ©swr atom (Apple's "writer software" QuickTime metadata)
    /// must round-trip what the caller supplied. Pre-D.5, the
    /// VariantMOVWriter default was "GlEnc 0.2.0" — a stale literal
    /// that leaked into every shipped MOV because EncodeQueue's
    /// WriterFactory never passed writerVersion explicitly. Post-D.5,
    /// the default falls back to a non-misleading "GlEnc" (no number).
    /// Production callers pass `AppVersion.writerVersion` from the app
    /// layer.
    ///
    /// This test covers two cases:
    ///   - Default (no writerVersion supplied) → atom body is "GlEnc"
    ///     (16-bit Pascal-style length + UTF-8 + 16-bit language code)
    ///   - Explicit writerVersion → atom body matches the supplied
    ///     string verbatim
    func testSwrAtomReflectsWriterVersion_DefaultIsBareGlEnc() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("glenc-d5-default-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try VariantMOVWriter(
            destURL: tmp, format: .dxt1,
            presentationWidth: 64, presentationHeight: 64, fps: 30)
        try writer.append(packet: Data(repeating: 0, count: 32),
                          presentationTime: .zero)
        try writer.finish()
        let s = try extractSwrString(at: tmp)
        XCTAssertEqual(s, "GlEnc",
                       "v0.9.2 D.5 default ©swr should be bare \"GlEnc\" with no version — got \(s.debugDescription)")
        XCTAssertFalse(s.contains("0.2.0"),
                       "©swr must never carry the stale Phase 2B 0.2.0 literal as a default")
    }

    func testSwrAtomReflectsWriterVersion_ExplicitVersionRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("glenc-d5-explicit-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try VariantMOVWriter(
            destURL: tmp, format: .dxt1,
            presentationWidth: 64, presentationHeight: 64, fps: 30,
            writerVersion: "GlEnc 9.9.9-test")
        try writer.append(packet: Data(repeating: 0, count: 32),
                          presentationTime: .zero)
        try writer.finish()
        let s = try extractSwrString(at: tmp)
        XCTAssertEqual(s, "GlEnc 9.9.9-test",
                       "explicit writerVersion must round-trip through the ©swr atom verbatim")
    }

    /// Read the udta/©swr atom from a MOV and return its decoded
    /// string. QuickTime user-data string-atom layout is
    /// `[length(2 B BE)] [language(2 B)] [UTF-8 string]`. Matches
    /// VariantMOVWriter.copyrightSwrBody (the producer).
    private func extractSwrString(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let moov = tree.children.first(where: { $0.type == "moov" }),
              let udta = moov.children.first(where: { $0.type == "udta" }),
              let swr = udta.children.first(where: { $0.type == "\u{00A9}swr" })
        else {
            throw NSError(domain: "D5Test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "moov/udta/©swr not found"])
        }
        let body = swr.bodyRange
        guard body.count >= 4 else {
            throw NSError(domain: "D5Test", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "©swr body < 4 bytes"])
        }
        let bytes = [UInt8](data[body])
        // bytes[0..1] = length BE16, bytes[2..3] = language, bytes[4..] = UTF-8.
        let len = (Int(bytes[0]) << 8) | Int(bytes[1])
        let stringStart = 4
        let stringEnd = stringStart + len
        guard stringEnd <= bytes.count else {
            throw NSError(domain: "D5Test", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "©swr length \(len) > body \(bytes.count - 4)"])
        }
        let stringBytes = Array(bytes[stringStart..<stringEnd])
        return String(bytes: stringBytes, encoding: .utf8) ?? ""
    }

    func testQuickTimePlayability() throws {
        // Smoke test: AVURLAsset can read it. Reports natural size, fps, and
        // a frame count derived from track duration. Doesn't actually decode
        // DXV (CoreVideo doesn't ship a DXV decoder), but does prove the
        // container is structurally valid for AVFoundation.
        let url = try encodePNGsToTempMOV()
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let tracks = try awaitOnce { try await asset.loadTracks(withMediaType: .video) }
        XCTAssertEqual(tracks.count, 1, "expected one video track")
        guard let track = tracks.first else { return }
        let size = try awaitOnce { try await track.load(.naturalSize) }
        let fps = try awaitOnce { try await track.load(.nominalFrameRate) }
        let dur = try awaitOnce { try await asset.load(.duration) }

        XCTAssertEqual(Int(size.width.rounded()),  1920, "natural width")
        XCTAssertEqual(Int(size.height.rounded()), 1080, "natural height")
        XCTAssertEqual(Float(fps.rounded()), 30.0, "fps")
        XCTAssertEqual(CMTimeGetSeconds(dur), 1.0, accuracy: 0.05, "1s duration")
    }

    // MARK: - deinit hygiene backstop — dealloc safety (deferred-ledger item 3)

    /// Abandon path: create + append, then drop the writer WITHOUT finish() so
    /// ARC deallocates it → its deinit closes the still-open handle once.
    /// Reaching the assertion proves the deinit ran without crashing (it is
    /// double-close-safe on the abandon path). This does NOT prove an fd leak
    /// was fixed — fd closure isn't cleanly observable, and FileHandle
    /// auto-closes at dealloc regardless; this asserts dealloc SAFETY only.
    func testAbandonedWriterAfterAppend_DeallocsWithoutCrash() throws {
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-abandon-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            let w = try VariantMOVWriter(destURL: out, format: .dxt1,
                presentationWidth: 64, presentationHeight: 64, fps: 30, codecFourCC: "DXD3")
            try w.append(packet: Data(repeating: 0xAB, count: 1024), presentationTime: .zero)
            // w leaves scope here → released → deinit runs (handle still open).
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                      "partial file written; abandoned writer deallocated without crash")
    }

    /// Success path: finish() closes + nils the handle, so at dealloc the
    /// deinit sees nil and no-ops → no double-close on the success path.
    func testFinishedWriter_DeallocsWithoutCrash() throws {
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-finished-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            let w = try VariantMOVWriter(destURL: out, format: .dxt1,
                presentationWidth: 64, presentationHeight: 64, fps: 30, codecFourCC: "DXD3")
            try w.append(packet: Data(repeating: 0xAB, count: 1024), presentationTime: .zero)
            try w.finish()
            // w leaves scope → deinit sees nil → no-op.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                      "finished writer deallocated without crash (deinit no-op on nil handle)")
    }
}

// MARK: - Atom comparison helper

private struct CompareReport {
    let summary: String
    /// Atoms whose bodies differ but are documented as encoder discretion.
    let discretionDiffs: [String]
    /// Atoms whose bodies differ AND are documented as spec-mandated. Test
    /// failures.
    let specMandatedDiffs: [String]
}

/// Mark each atom path as spec-mandated or discretion based on Pass A
/// FINDINGS.md classifications. Anything not listed defaults to spec-mandated
/// so we don't accidentally let new divergences slip through.
private func atomDiscretion(_ path: String) -> Bool {
    let discretionPaths: Set<String> = [
        // mdat content — every encoder writes different LZ-payload bytes per
        // Pass A. The byte-equivalence to ffmpeg is verified separately by
        // testFrameByteEquality_postWriter.
        "mdat",
        // Sample table: chunking and per-sample sizes follow encoder choices.
        "moov/trak/mdia/minf/stbl/stsc",
        "moov/trak/mdia/minf/stbl/stsz",
        "moov/trak/mdia/minf/stbl/stco",
        // stsd outer body — its size differs because we omit fiel/pasp/
        // encoder-name extension atoms (Alley/AME shape, not FFmpeg's).
        // The substantive 78-byte VisualSampleEntry inside is verified
        // separately by testStsdSubstantiveFieldsMatch.
        "moov/trak/mdia/minf/stbl/stsd",
        // udta contents are encoder discretion ("GlEnc x.y.z" vs
        // "Lavf62.12.101" vs "Resolume"). The presence of udta is what we
        // mimic, not the bytes.
        "moov/udta",
        "moov/udta/©swr",
    ]
    return discretionPaths.contains(path)
}

private func compareMOVs(label: String, our: Data, theirs: Data) -> CompareReport {
    let ourTree = AtomTree(data: our, range: 0..<our.count)
    let theirTree = AtomTree(data: theirs, range: 0..<theirs.count)

    var lines: [String] = []
    var specMandatedDiffs: [String] = []
    var discretionDiffs: [String] = []
    lines.append("=== Atom diff \(label) ===")
    lines.append(String(format: "  ours:   %d bytes (%d top-level atoms)",
                        our.count, ourTree.children.count))
    lines.append(String(format: "  theirs: %d bytes (%d top-level atoms)",
                        theirs.count, theirTree.children.count))

    diff(ourTree.children, theirTree.children, prefix: "",
         data1: our, data2: theirs,
         lines: &lines,
         specMandatedDiffs: &specMandatedDiffs,
         discretionDiffs: &discretionDiffs)

    lines.append("Result: \(specMandatedDiffs.count) spec-mandated diffs, \(discretionDiffs.count) discretion diffs.")
    return CompareReport(
        summary: lines.joined(separator: "\n"),
        discretionDiffs: discretionDiffs,
        specMandatedDiffs: specMandatedDiffs)
}

private func diff(
    _ a: [AtomNode], _ b: [AtomNode], prefix: String,
    data1: Data, data2: Data,
    lines: inout [String],
    specMandatedDiffs: inout [String],
    discretionDiffs: inout [String]
) {
    // Match by atom type pairwise. If both sides contain the same atom type
    // exactly once at this level, walk into it. If ordering or counts differ,
    // report.
    let aTypes = a.map { $0.type }
    let bTypes = b.map { $0.type }
    if aTypes != bTypes {
        let path = prefix.isEmpty ? "(top)" : prefix
        let line = "  [\(path)] child sequence: ours=\(aTypes) theirs=\(bTypes)"
        lines.append(line)
        // mdat ordering vs moov is encoder discretion (front- vs end-of-file
        // moov). Otherwise treat as spec-mandated.
        let bothHaveSameSet = Set(aTypes) == Set(bTypes)
        if bothHaveSameSet {
            discretionDiffs.append(line)
        } else {
            specMandatedDiffs.append(line)
        }
    }
    for ourChild in a {
        let path = prefix.isEmpty ? ourChild.type : "\(prefix)/\(ourChild.type)"
        guard let theirChild = b.first(where: { $0.type == ourChild.type }) else {
            let line = "  [\(path)] only in ours"
            lines.append(line)
            if atomDiscretion(path) {
                discretionDiffs.append(line)
            } else {
                specMandatedDiffs.append(line)
            }
            continue
        }
        // Body comparison
        let ourBody = data1[ourChild.bodyRange]
        let theirBody = data2[theirChild.bodyRange]
        let bodyEqual = ourBody.elementsEqual(theirBody)

        if isContainerAtom(ourChild.type) {
            // Recurse rather than compare bodies directly (children may
            // shift due to inner discretion).
            diff(ourChild.children, theirChild.children, prefix: path,
                 data1: data1, data2: data2,
                 lines: &lines,
                 specMandatedDiffs: &specMandatedDiffs,
                 discretionDiffs: &discretionDiffs)
        } else if !bodyEqual {
            let line = String(format: "  [%@] body differs (ours=%db, theirs=%db)",
                              path, ourBody.count, theirBody.count)
            lines.append(line)
            if atomDiscretion(path) {
                discretionDiffs.append(line)
            } else {
                specMandatedDiffs.append(line)
            }
        } else {
            lines.append("  [\(path)] body MATCH (\(ourBody.count) bytes)")
        }
    }
    for theirChild in b where !a.contains(where: { $0.type == theirChild.type }) {
        let path = prefix.isEmpty ? theirChild.type : "\(prefix)/\(theirChild.type)"
        let line = "  [\(path)] only in theirs"
        lines.append(line)
        if atomDiscretion(path) {
            discretionDiffs.append(line)
        } else {
            specMandatedDiffs.append(line)
        }
    }
}

private func isContainerAtom(_ type: String) -> Bool {
    return [
        "moov", "trak", "edts", "mdia", "minf", "dinf", "stbl", "udta",
    ].contains(type)
}

// MARK: - Atom tree

private struct AtomNode {
    let type: String
    let range: Range<Int>       // full atom incl. header
    let bodyRange: Range<Int>   // body only
    let children: [AtomNode]
}

private struct AtomTree {
    let data: Data
    let children: [AtomNode]

    init(data: Data, range: Range<Int>) {
        self.data = data
        self.children = AtomTree.parse(data: data, range: range)
    }

    private static func parse(data: Data, range: Range<Int>) -> [AtomNode] {
        var out: [AtomNode] = []
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            let sz32 = Int(MOVFrameExtractor.readBE32(data, at: p))
            // Use Latin-1 so non-ASCII atom types like `©swr` (0xa9 0x73 0x77 0x72)
            // are decoded as the © character rather than falling back to "?".
            let typeStr = String(bytes: data[(p+4)..<(p+8)], encoding: .isoLatin1) ?? "????"
            let bodyStart: Int
            let atomEnd: Int
            if sz32 == 0 {
                bodyStart = p + 8
                atomEnd = range.upperBound
            } else if sz32 == 1 {
                let large = Int(MOVFrameExtractor.readBE64(data, at: p + 8))
                bodyStart = p + 16
                atomEnd = p + large
            } else {
                bodyStart = p + 8
                atomEnd = p + sz32
            }
            // Recurse for known containers + stsd's children.
            let kids: [AtomNode]
            if isContainerAtomType(typeStr) {
                kids = AtomTree.parse(data: data, range: bodyStart..<atomEnd)
            } else if typeStr == "stsd" {
                // stsd body = 4 v+f + 4 entry_count + atoms
                let inner = bodyStart + 8
                kids = AtomTree.parse(data: data, range: inner..<atomEnd)
            } else {
                kids = []
            }
            out.append(AtomNode(type: typeStr,
                                range: p..<atomEnd,
                                bodyRange: bodyStart..<atomEnd,
                                children: kids))
            p = atomEnd
            if sz32 == 0 { break }
        }
        return out
    }

    private static func isContainerAtomType(_ t: String) -> Bool {
        return ["moov","trak","edts","mdia","minf","dinf","stbl","udta"].contains(t)
    }
}

// MARK: - Async helper for XCTest

private func awaitOnce<T>(_ block: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task.detached {
        do {
            let value = try await block()
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    switch result! {
    case .success(let v): return v
    case .failure(let e): throw e
    }
}

// MARK: - Bridge to PNG loader from DXT1EncoderTests

/// Re-uses the loader from DXT1EncoderTests by exposing it to this file via
/// a tiny shim. The original loader is private; we recreate it here so the
/// test file stays self-contained.
enum DXT1EncoderTests_PNGLoader {
    static func loadPNGAsBGRAPixelFrame(url: URL, width: Int, height: Int) throws -> PixelFrame {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(domain: "PNGLoader", code: 1)
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
            throw NSError(domain: "PNGLoader", code: 2)
        }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "PNGLoader", code: 3)
        }
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: space, bitmapInfo: bitmapInfo)
        else {
            CVPixelBufferUnlockBaseAddress(buf, [])
            throw NSError(domain: "PNGLoader", code: 4)
        }
        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buf, [])
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero)
    }
}

import CoreVideo
import CoreGraphics
import ImageIO
import AVFoundation
