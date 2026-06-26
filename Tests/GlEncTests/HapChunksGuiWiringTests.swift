// SPDX-License-Identifier: MIT
//
// HapChunksGuiWiringTests — Slice 4 GUI→encoder wiring proof.
//
// Slice 4 surfaced the HAP chunk count in the GUI: a per-job `hapChunks`
// field (EncodeJob), a persisted default (AppSettings.defaultHapChunks)
// that seeds new jobs, and a codec-row Stepper bound to it (HAP-gated).
// The live app confirms the UI surface — the codec-row Stepper appears
// for HAP variants and hides for DXV3, and a new job created with
// defaultHapChunks=4 shows "Chunks: 4". What the SwiftUI Stepper's
// increment chevron and the toolbar Encode button do NOT accept is a
// synthetic mouse click (a known accessibility-automation limitation),
// so the value-propagation + clamp + encoder-reaching legs are proven
// here against the EXACT code paths the GUI runs:
//
//   - addJobs seeds job.hapChunks from AppSettings.defaultHapChunks
//     (the same read EncodeQueue.addJobs performs for new rows).
//   - EncodeJob clamps hapChunks to 1...64 (the Stepper's `in:` range
//     enforces the same bound by construction in the UI).
//   - A HapY job's hapChunks flows through the SAME EncodeRequest
//     construction startEncode uses (codec: outputCodec, hapChunks:
//     <job>.hapChunks) and reaches the encoder: chunks 4 → top-level
//     section byte 0xCF, chunks 1 → 0xBF. (The 0xC_ chunk behavior
//     itself is Slice 1–3; this asserts the GUI field is the thing
//     driving it.)

import XCTest
import Foundation
@testable import GlEnc
@testable import GlEncCore
import GlanceCore

@MainActor
final class HapChunksGuiWiringTests: XCTestCase {

    /// A real, readable source so addJobs' async alpha probe doesn't error
    /// and so the encode leg has frames. Repo-relative from this file.
    private static var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GlEncTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo
            .appendingPathComponent("reference/dxt5/source/source.mov")
    }

    override func tearDown() {
        // The seeding test mutates the shared singleton; restore the
        // factory default so no other test sees a stray value.
        AppSettings.shared.resetToDefaults()
        super.tearDown()
    }

    // MARK: - (d) new jobs seed hapChunks from the persisted default

    func testNewJobSeedsHapChunksFromPersistedDefault() {
        // Mirrors the live-app check: with the persisted default at 4, a
        // newly-added job carries hapChunks == 4 (not the hard-coded 1).
        AppSettings.shared.defaultHapChunks = 4
        let queue = EncodeQueue()
        queue.addJobs(urls: [Self.sourceURL])
        XCTAssertEqual(queue.jobs.last?.hapChunks, 4,
            "addJobs must seed job.hapChunks from AppSettings.defaultHapChunks")

        // And the default-1 case stays 1 (byte-identical to pre-Slice-4).
        AppSettings.shared.defaultHapChunks = 1
        let queue2 = EncodeQueue()
        queue2.addJobs(urls: [Self.sourceURL])
        XCTAssertEqual(queue2.jobs.last?.hapChunks, 1,
            "default 1 must seed hapChunks == 1 (single-section)")
    }

    // MARK: - AppSettings persistence + on-read clamp

    func testAppSettingsHapChunksPersistsAndClamps() {
        let suiteName = "glenc-test-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suiteName)!
        ud.removePersistentDomain(forName: suiteName)

        // Fresh install (key never set) → 1, not integer(forKey:)'s 0.
        XCTAssertEqual(AppSettings(userDefaults: ud).defaultHapChunks, 1)

        // Round-trips a valid value through a second instance.
        let s1 = AppSettings(userDefaults: ud)
        s1.defaultHapChunks = 8
        XCTAssertEqual(AppSettings(userDefaults: ud).defaultHapChunks, 8)

        // Out-of-range stored values clamp on read to 1...64.
        ud.set(0, forKey: "glenc.defaultHapChunks")
        XCTAssertEqual(AppSettings(userDefaults: ud).defaultHapChunks, 1)
        ud.set(999, forKey: "glenc.defaultHapChunks")
        XCTAssertEqual(AppSettings(userDefaults: ud).defaultHapChunks, 64)
    }

    // MARK: - (b) EncodeJob clamps hapChunks to 1...64

    func testEncodeJobClampsHapChunks() {
        XCTAssertEqual(EncodeJob(sourceURL: Self.sourceURL, format: .hapY, hapChunks: 4).hapChunks, 4)
        XCTAssertEqual(EncodeJob(sourceURL: Self.sourceURL, format: .hapY, hapChunks: 100).hapChunks, 64,
            "above-range must clamp to 64")
        XCTAssertEqual(EncodeJob(sourceURL: Self.sourceURL, format: .hapY, hapChunks: 0).hapChunks, 1,
            "below-range must clamp to 1")
        XCTAssertEqual(EncodeJob(sourceURL: Self.sourceURL, format: .hapY).hapChunks, 1,
            "default field value is 1 (single-section)")
    }

    // MARK: - (c) job.hapChunks reaches the encoder → 0xCF @ 4 / 0xBF @ 1

    func testHapYJobHapChunksReachesEncoderProducing0xCF() async throws {
        let src = Self.sourceURL
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
            "source fixture missing (git-lfs pull): \(src.path)")

        // Encode through the SAME EncodeRequest shape startEncode builds
        // from a job snapshot: codec: job.outputCodec, hapChunks:
        // job.hapChunks. The only variable is the GUI-owned hapChunks.
        func encodeAndProbeFrame0(jobChunks: Int) async throws -> UInt8 {
            let job = EncodeJob(sourceURL: src, format: .hapY, hapChunks: jobChunks)
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("slice4-wiring-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: out) }
            let req = EncodeRequest(
                sourceURL: job.sourceURL,
                outputURL: out,
                codec: job.outputCodec,          // .dxv(.hapY)
                writerVersion: "slice4-wiring-test",
                hapChunks: job.hapChunks)        // the GUI field
            try await CoreEncoder.makePipeline(req).run()

            let index = try HAPDemuxer.demux(url: out)
            let data = try Data(contentsOf: out)
            let f0 = index.frames[0]
            let packet = data.subdata(in: Int(f0.fileOffset)..<(Int(f0.fileOffset) + Int(f0.size)))
            return try HAPPacketDecoder.parseSectionHeader(packet: packet).sectionType
        }

        // A HapY job with hapChunks == 4 emits the chunked 0xCF section…
        let chunked = try await encodeAndProbeFrame0(jobChunks: 4)
        XCTAssertEqual(chunked, 0xCF,
            "GUI hapChunks=4 on a HapY job must reach the encoder as a 0xCF chunked section")
        // …and hapChunks == 1 stays the single-section 0xBF (additive).
        let single = try await encodeAndProbeFrame0(jobChunks: 1)
        XCTAssertEqual(single, 0xBF,
            "GUI hapChunks=1 must stay single-section 0xBF (byte-identical to pre-Slice-4)")
    }
}
