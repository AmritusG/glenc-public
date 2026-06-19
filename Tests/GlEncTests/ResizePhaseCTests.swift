/*
 * ResizePhaseCTests — Resize Release Phase C.
 *
 * Tests the data-model + persistence wiring:
 *   - EncodeJob's two new fields default to .original / .auto
 *   - AppSettings.defaultResizeQuality round-trips via UserDefaults
 *     (rawValue path — mirrors defaultQuality)
 *   - AppSettings.defaultOutputSize round-trips via UserDefaults
 *     (JSON path) for all three OutputSize cases
 *   - A corrupt or missing stored OutputSize falls back to .original
 *     rather than crashing
 *   - EncodeQueue.addJobs inherits both persisted defaults into
 *     freshly-created jobs
 *
 * State hygiene: setUp/tearDown saves and restores the affected
 * AppSettings.shared fields so other tests aren't poisoned by the
 * singleton mutation — same discipline as HapMGuiPathRegressionTests.
 */

import XCTest
import Foundation
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class ResizePhaseC_EncodeJobTests: XCTestCase {

    /// A freshly-constructed `EncodeJob` (no explicit outputSize /
    /// resizeQuality args) defaults to `.original` / `.auto` — the
    /// Phase C-locked defaults that mean "no behavior change for any
    /// existing call site."
    func testDefaultEncodeJobHasResizeDefaults() {
        let job = EncodeJob(sourceURL: URL(fileURLWithPath: "/tmp/probe.mov"))
        XCTAssertEqual(job.outputSize, .original,
                       "EncodeJob default outputSize must be .original")
        XCTAssertEqual(job.resizeQuality, .auto,
                       "EncodeJob default resizeQuality must be .auto")
    }

    /// Explicit non-default args land on the struct.
    func testExplicitEncodeJobArgsLand() {
        let job = EncodeJob(
            sourceURL: URL(fileURLWithPath: "/tmp/probe.mov"),
            format: .hapM,
            outputSize: .preset(.fhd_1920_1080),
            resizeQuality: .lanczos)
        XCTAssertEqual(job.outputSize, .preset(.fhd_1920_1080))
        XCTAssertEqual(job.resizeQuality, .lanczos)
    }
}

@MainActor
final class ResizePhaseC_AppSettingsTests: XCTestCase {

    /// Each test uses its own UserDefaults suite to avoid polluting
    /// the standard store (production singleton uses .standard).
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "ResizePhaseC-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - ResizeQuality round-trip (rawValue path)

    func testResizeQualityRoundTrip() {
        for q in ResizeQuality.allCases {
            let s = AppSettings(userDefaults: suite)
            s.defaultResizeQuality = q
            // Re-read by instantiating a fresh settings object from
            // the same UserDefaults suite.
            let s2 = AppSettings(userDefaults: suite)
            XCTAssertEqual(s2.defaultResizeQuality, q,
                           "ResizeQuality \(q) failed UserDefaults round-trip")
        }
    }

    /// Fresh suite (no prior write) → defaultResizeQuality should be
    /// the documented Phase C default `.auto`.
    func testResizeQualityDefaultIsAuto() {
        let s = AppSettings(userDefaults: suite)
        XCTAssertEqual(s.defaultResizeQuality, .auto,
                       "Fresh AppSettings.defaultResizeQuality must default to .auto")
    }

    // MARK: - OutputSize round-trip (JSON path)

    func testOutputSizeRoundTripOriginal() {
        let s = AppSettings(userDefaults: suite)
        s.defaultOutputSize = .original
        let s2 = AppSettings(userDefaults: suite)
        XCTAssertEqual(s2.defaultOutputSize, .original)
    }

    func testOutputSizeRoundTripPreset() {
        let s = AppSettings(userDefaults: suite)
        s.defaultOutputSize = .preset(.fhd_1920_1080)
        let s2 = AppSettings(userDefaults: suite)
        XCTAssertEqual(s2.defaultOutputSize, .preset(.fhd_1920_1080))
    }

    func testOutputSizeRoundTripCustom() {
        let s = AppSettings(userDefaults: suite)
        s.defaultOutputSize = .custom(width: 1500, height: 844)
        let s2 = AppSettings(userDefaults: suite)
        XCTAssertEqual(s2.defaultOutputSize, .custom(width: 1500, height: 844))
    }

    /// Fresh suite (no prior write) → defaultOutputSize falls through
    /// to `.original` per the Phase C default.
    func testOutputSizeDefaultIsOriginal() {
        let s = AppSettings(userDefaults: suite)
        XCTAssertEqual(s.defaultOutputSize, .original,
                       "Fresh AppSettings.defaultOutputSize must default to .original")
    }

    /// CORRUPT stored OutputSize falls back to `.original` rather than
    /// crashing. Simulates a stored Data that's syntactically invalid
    /// JSON, or valid JSON for a non-OutputSize shape.
    func testOutputSizeCorruptStoredValueFallsBackToOriginal() {
        // Inject garbage bytes under the documented key.
        let garbage = Data([0x00, 0x01, 0xFF, 0xCA, 0xFE])
        suite.set(garbage, forKey: "glenc.defaultOutputSize")
        let s = AppSettings(userDefaults: suite)
        XCTAssertEqual(s.defaultOutputSize, .original,
                       "Corrupt stored OutputSize must fall back to .original")
    }

    /// Valid-JSON-but-wrong-shape stored value also falls back.
    /// (try? on the decode → nil → .original.)
    func testOutputSizeWrongJSONShapeFallsBackToOriginal() {
        let wrongShape: Data = #"{"unrelated":"key"}"#.data(using: .utf8)!
        suite.set(wrongShape, forKey: "glenc.defaultOutputSize")
        let s = AppSettings(userDefaults: suite)
        XCTAssertEqual(s.defaultOutputSize, .original,
                       "Wrong-shape JSON OutputSize must fall back to .original")
    }
}

@MainActor
final class ResizePhaseC_EncodeQueueInheritanceTests: XCTestCase {

    /// Save/restore AppSettings.shared affected fields per-test —
    /// the queue's addJobs reads the singleton (not an injected
    /// suite), so cross-test pollution must be guarded.
    private var savedDefaultResizeQuality: ResizeQuality?
    private var savedDefaultOutputSize: OutputSize?
    private var savedDefaultQuality: QualityTier?
    private var savedDefaultAlpha: AlphaMode?

    override func setUp() async throws {
        try await super.setUp()
        let s = AppSettings.shared
        savedDefaultResizeQuality = s.defaultResizeQuality
        savedDefaultOutputSize = s.defaultOutputSize
        savedDefaultQuality = s.defaultQuality
        savedDefaultAlpha = s.defaultAlpha
    }

    override func tearDown() async throws {
        let s = AppSettings.shared
        if let v = savedDefaultResizeQuality { s.defaultResizeQuality = v }
        if let v = savedDefaultOutputSize { s.defaultOutputSize = v }
        if let v = savedDefaultQuality { s.defaultQuality = v }
        if let v = savedDefaultAlpha { s.defaultAlpha = v }
        try await super.tearDown()
    }

    /// A freshly-dropped clip via `EncodeQueue.addJobs(urls:)` picks
    /// up `AppSettings.shared.defaultResizeQuality` and
    /// `defaultOutputSize`. Mirrors how `addJobs` already inherits
    /// `defaultFormat` from the queue's tier/alpha defaults.
    func testAddJobsInheritsResizeDefaults() {
        // Set non-default values in AppSettings.
        AppSettings.shared.defaultResizeQuality = .lanczos
        AppSettings.shared.defaultOutputSize = .preset(.fhd_1920_1080)

        let q = EncodeQueue()
        q.addJobs(urls: [URL(fileURLWithPath: "/tmp/probe.mov")])

        XCTAssertEqual(q.jobs.count, 1)
        XCTAssertEqual(q.jobs[0].resizeQuality, .lanczos,
                       "addJobs should pick up AppSettings.defaultResizeQuality")
        XCTAssertEqual(q.jobs[0].outputSize, .preset(.fhd_1920_1080),
                       "addJobs should pick up AppSettings.defaultOutputSize")
    }

    /// Sanity-check the Phase C defaults flow when AppSettings holds
    /// the documented defaults (`.auto` / `.original`): a freshly-
    /// dropped clip should not gain any unexpected behavior.
    func testAddJobsWithFactoryDefaultsProducesOriginalAndAuto() {
        AppSettings.shared.defaultResizeQuality = .auto
        AppSettings.shared.defaultOutputSize = .original

        let q = EncodeQueue()
        q.addJobs(urls: [URL(fileURLWithPath: "/tmp/probe.mov")])

        XCTAssertEqual(q.jobs[0].resizeQuality, .auto)
        XCTAssertEqual(q.jobs[0].outputSize, .original)
    }

    /// Custom dims survive the AppSettings → addJobs → EncodeJob hop.
    /// Tests JSON round-trip indirectly via AppSettings's setter.
    func testAddJobsInheritsCustomOutputSize() {
        AppSettings.shared.defaultOutputSize = .custom(width: 1500, height: 844)
        AppSettings.shared.defaultResizeQuality = .bilinear

        let q = EncodeQueue()
        q.addJobs(urls: [URL(fileURLWithPath: "/tmp/probe.mov")])

        XCTAssertEqual(q.jobs[0].outputSize, .custom(width: 1500, height: 844))
        XCTAssertEqual(q.jobs[0].resizeQuality, .bilinear)
    }
}
