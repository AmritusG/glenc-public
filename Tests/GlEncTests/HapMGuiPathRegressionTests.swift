/*
 * HapMGuiPathRegressionTests — v0.9.3 Phase E.
 *
 * Closes the test gap Phase D.1 identified. Phase C's
 * testEndToEnd_DispatchProducesValidHapM constructs
 * HapFrameEncoder(codec: .hapM) directly — it skips the GUI's
 * (Codec × Alpha) resolver, the EncodeQueue.addJobs path, the
 * encodeAll dispatch, the snapshot construction, and the writer
 * factory wiring. None of those upstream steps were under any
 * automated assertion until Phase E.
 *
 * Each test here:
 *   - Builds a real `EncodeQueue`.
 *   - Sets `defaultTier` / `defaultAlpha` to the UI-equivalent
 *     selection — these are the same `@Published` properties the
 *     defaults-row Menus write to in ContentView.
 *   - Configures `AppSettings.shared` so output lands in a tempdir
 *     and collisions auto-rename (no user-prompt suspension under
 *     test, and no clobbering of the user's real test outputs).
 *   - Drops a real source movie via `addJobs(urls:)`.
 *   - Drives `encodeAll()` to completion, polling `isEncoding`.
 *   - Asserts on the WRITTEN FILE's stsd FourCC and first sample
 *     leading section type — not on the in-memory `jobs[i].format`
 *     (which Phase D.1's deleted diagnostic harness already
 *     exercised in isolation).
 *
 * The positive case proves the .hapQ × .withAlpha branch lands a
 * HapM file on disk. The two negative spot-checks pin the HAP-vs-
 * HAP-Q boundary the Phase D.1 _Hap5 incident brushed against.
 */

import XCTest
import Foundation
import CoreVideo
import CoreMedia
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class HapMGuiPathRegressionTests: XCTestCase {

    // Local-only HAP test clip, supplied via GLENC_HAP_TESTCLIP_SRC so no
    // personal path is committed. Empty when unset → the fileExists guard in
    // the consuming test skips cleanly.
    private static let realSource = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["GLENC_HAP_TESTCLIP_SRC"] ?? "")

    // MARK: - State save/restore so we don't poison the shared singleton

    private var savedDefaultQuality: QualityTier?
    private var savedDefaultAlpha: AlphaMode?
    private var savedOutputLocation: AppSettings.OutputLocation?
    private var savedFixedOutputPath: String?
    private var savedCollisionPolicy: AppSettings.CollisionPolicy?
    private var outputDir: URL?

    override func setUp() async throws {
        try await super.setUp()
        let s = AppSettings.shared
        savedDefaultQuality = s.defaultQuality
        savedDefaultAlpha = s.defaultAlpha
        savedOutputLocation = s.outputLocation
        savedFixedOutputPath = s.fixedOutputPath
        savedCollisionPolicy = s.collisionPolicy
        // Per-test tempdir so concurrent tests don't collide.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hap-m-gui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        outputDir = dir
        s.outputLocation = .fixed
        s.fixedOutputPath = dir.path
        s.collisionPolicy = .autoRename
    }

    override func tearDown() async throws {
        let s = AppSettings.shared
        if let v = savedDefaultQuality { s.defaultQuality = v }
        if let v = savedDefaultAlpha { s.defaultAlpha = v }
        if let v = savedOutputLocation { s.outputLocation = v }
        if let v = savedFixedOutputPath { s.fixedOutputPath = v }
        if let v = savedCollisionPolicy { s.collisionPolicy = v }
        if let dir = outputDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try await super.tearDown()
    }

    // MARK: - The headline regression test

    /// (.hapQ, .withAlpha) — the case the Phase D.1 _Hap5 incident
    /// concerned — must produce a written file whose stsd FourCC is
    /// "HapM" and whose first sample outer section type is 0x0D.
    func testGuiResolver_HAPQ_withAlpha_writesHapM() async throws {
        try await runGuiPathEncode(
            tier: .hapQ, alpha: .withAlpha,
            expectedFourCC: "HapM",
            expectedOuterSectionType: 0x0D,
            expectedSectionMeaning: "HapM outer wrapper")
    }

    // MARK: - Negative spot-checks pinning the HAP-vs-HAP-Q boundary

    /// (.hapQ, .withoutAlpha) — HapY (HAP Q minus alpha). Confirms
    /// the resolver matrix's "no alpha" axis still works post-Phase-D.
    func testGuiResolver_HAPQ_withoutAlpha_writesHapY() async throws {
        try await runGuiPathEncode(
            tier: .hapQ, alpha: .withoutAlpha,
            expectedFourCC: "HapY",
            expectedOuterSectionType: 0xBF,
            expectedSectionMeaning: "Snappy-compressed scaled YCoCg DXT5")
    }

    /// (.hap, .withAlpha) — Hap5 (HAP with alpha). This is the
    /// EXACT format the Phase D.1 click-test produced when the user
    /// believed they had selected HAP Q. Locking the (.hap × .withAlpha)
    /// → Hap5 boundary makes it impossible for a future refactor to
    /// silently flip the wrong cell of the resolver matrix without
    /// the suite catching it.
    func testGuiResolver_HAP_withAlpha_writesHap5() async throws {
        try await runGuiPathEncode(
            tier: .hap, alpha: .withAlpha,
            expectedFourCC: "Hap5",
            expectedOuterSectionType: 0xBE,
            expectedSectionMeaning: "Snappy-compressed DXT5")
    }

    // MARK: - Shared driver

    /// Drive the resolver → addJobs → encodeAll → written-file path
    /// for a single (tier, alpha) combination and assert the
    /// written file's structural identity.
    private func runGuiPathEncode(
        tier: QualityTier, alpha: AlphaMode,
        expectedFourCC: String,
        expectedOuterSectionType: UInt8,
        expectedSectionMeaning: String
    ) async throws {
        guard FileManager.default.fileExists(atPath: Self.realSource.path) else {
            throw XCTSkip("source.mov missing — skipping GUI-path regression")
        }

        let q = EncodeQueue()
        // Mirror the defaults-row UI bindings — these are the same
        // @Published properties ContentView.defaultsRow writes to.
        q.defaultTier = tier
        q.defaultAlpha = alpha

        // Drop a clip via the public addJobs API.
        q.addJobs(urls: [Self.realSource])
        XCTAssertEqual(q.jobs.count, 1, "addJobs should produce one job")

        // Run the encoder serial loop. encodeAll spawns a detached
        // Task and returns immediately; poll isEncoding until done.
        q.encodeAll()
        let deadline = Date().addingTimeInterval(120)
        while q.isEncoding && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(q.isEncoding, "encode timed out after 120s")
        guard let job = q.jobs.first else {
            return XCTFail("queue empty after encodeAll")
        }
        XCTAssertEqual(job.status, .done,
                       "job status not .done after encode: \(job.status); errorMessage=\(job.errorMessage ?? "nil")")
        guard let outURL = job.outputURL else {
            return XCTFail("job.outputURL is nil after .done")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                      "output file does not exist at \(outURL.path)")

        // ===== Assertions on the WRITTEN FILE (NOT on jobs[0].format) =====
        let data = try Data(contentsOf: outURL)
        XCTAssertGreaterThan(data.count, 100, "output file too small")

        // stsd codec FourCC.
        let stsdFourCC = try readStsdFourCC(from: data)
        XCTAssertEqual(stsdFourCC, expectedFourCC,
                       "(\(tier), \(alpha)) wrote stsd FourCC \(stsdFourCC); expected \(expectedFourCC)")

        // First sample leading section byte (definitive byte-level
        // identity — outer 0x0D for HapM, 0xBF for HapY, 0xBE for Hap5).
        let firstSample = try readFirstSampleBytes(from: data)
        XCTAssertGreaterThanOrEqual(firstSample.count, 4,
                                    "first sample too short for HAP header")
        XCTAssertEqual(firstSample[3], expectedOuterSectionType,
                       String(format: "(\(tier), \(alpha)) first-sample section type 0x%02X; expected 0x%02X (%@)",
                              firstSample[3], expectedOuterSectionType, expectedSectionMeaning))
    }

    // MARK: - Minimal MOV parser (private, inline)

    /// Read the first stsd sample-entry FourCC (4 bytes at offset 12
    /// within the stsd body, after the 4-byte v+f, 4-byte entry_count,
    /// 4-byte first-entry size).
    private func readStsdFourCC(from data: Data) throws -> String {
        guard let stsd = findAtom(in: data, path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else {
            throw NSError(domain: "HapMGuiTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "stsd not found"])
        }
        let off = stsd.bodyStart + 12
        guard off + 4 <= stsd.bodyEnd else {
            throw NSError(domain: "HapMGuiTest", code: 2)
        }
        return String(bytes: data[off..<(off + 4)], encoding: .isoLatin1) ?? ""
    }

    /// Read the first video sample's bytes from disk via stco + stsz.
    private func readFirstSampleBytes(from data: Data) throws -> Data {
        guard let stsz = findAtom(in: data, path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = findAtom(in: data, path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            throw NSError(domain: "HapMGuiTest", code: 3)
        }
        // stsz body: 4B v+f, 4B sample_size, 4B count, then per-sample
        // sizes (when sample_size == 0).
        let constSize = readBE32(data, at: stsz.bodyStart + 4)
        let firstSampleSize: Int
        if constSize != 0 {
            firstSampleSize = Int(constSize)
        } else {
            firstSampleSize = Int(readBE32(data, at: stsz.bodyStart + 12))
        }
        // stco body: 4B v+f, 4B count, then 4B per offset.
        let firstSampleOffset = Int(readBE32(data, at: stco.bodyStart + 8))
        return data.subdata(in: firstSampleOffset..<(firstSampleOffset + firstSampleSize))
    }

    // MARK: - Atom walker

    private struct AtomLocation {
        let bodyStart: Int
        let bodyEnd: Int
    }

    private func findAtom(in data: Data, path: [String]) -> AtomLocation? {
        return findAtomIn(data: data, range: 0..<data.count, path: path)
    }

    private func findAtomIn(data: Data, range: Range<Int>, path: [String]) -> AtomLocation? {
        guard let head = path.first else { return nil }
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            let sz = Int(readBE32(data, at: p))
            let typ = String(bytes: data[(p+4)..<(p+8)], encoding: .isoLatin1) ?? "????"
            let bodyStart: Int
            let atomEnd: Int
            if sz == 1 {
                let large = Int(readBE64(data, at: p + 8))
                bodyStart = p + 16
                atomEnd = p + large
            } else if sz == 0 {
                bodyStart = p + 8
                atomEnd = range.upperBound
            } else {
                bodyStart = p + 8
                atomEnd = p + sz
            }
            if typ == head {
                let bodyEnd = atomEnd
                if path.count == 1 {
                    return AtomLocation(bodyStart: bodyStart, bodyEnd: bodyEnd)
                }
                let nestedRange: Range<Int>
                if typ == "stsd" {
                    // stsd body: 4B v+f, 4B entry_count, then entries.
                    nestedRange = (bodyStart + 8)..<bodyEnd
                } else {
                    nestedRange = bodyStart..<bodyEnd
                }
                return findAtomIn(data: data, range: nestedRange,
                                  path: Array(path.dropFirst()))
            }
            p = atomEnd
            if sz == 0 { break }
        }
        return nil
    }

    private func readBE32(_ data: Data, at index: Int) -> UInt32 {
        let b0 = UInt32(data[index])
        let b1 = UInt32(data[index + 1])
        let b2 = UInt32(data[index + 2])
        let b3 = UInt32(data[index + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private func readBE64(_ data: Data, at index: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[index + i]) }
        return v
    }
}
