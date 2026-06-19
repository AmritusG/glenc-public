/*
 * EncodeQueueTests — Phase 7A unit tests for the queue view model.
 *
 * Covers the Phase 7A behaviors the GUI relies on:
 *   - Global defaults inherit at add-time; per-row override is
 *     decoupled from later default mutations.
 *   - Per-row format mutations stick.
 *   - cancel(id:) on a queued job marks it failed-with-Cancelled.
 *   - cancelAll() during encode cancels the in-flight job and the
 *     remaining queue.
 *   - removeJob and clearCompleted shape the queue correctly.
 *
 * Cancellation tests use the queue's `_testEncodeJobHook` to
 * substitute a controllable closure for the real EncodePipeline.
 * The hook awaits a small sleep and respects Task.isCancelled so
 * cancellation timing is observable without running a real 4K
 * encode in the test process.
 */

import XCTest
import Foundation
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class EncodeQueueTests: XCTestCase {

    // Phase 7B-a — reset the AppSettings singleton (backed by
    // UserDefaults.standard) before and after each test. Without this,
    // EncodeQueue's `defaultTier`/`defaultAlpha` didSet mirrors leak
    // mutations into the xctest tool's persistent defaults domain,
    // breaking subsequent test runs that read those leaked values.
    override func setUp() {
        super.setUp()
        AppSettings.shared.resetToDefaults()
    }
    override func tearDown() {
        AppSettings.shared.resetToDefaults()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeURL(_ name: String) -> URL {
        // Hand-crafted file URLs — these never need to exist for the
        // queue's data-only tests, and the cancellation tests use the
        // test hook which doesn't touch the filesystem.
        URL(fileURLWithPath: "/tmp/glenc-test-\(name).mov")
    }

    /// Slow-stub hook for cancellation tests. Sleeps ~5 ms in 1-ms
    /// chunks while checking `Task.isCancelled` — short enough to keep
    /// the test fast, granular enough that cancellation arrives mid-
    /// loop on any reasonable machine.
    private func slowStubHook(stepMs: UInt64 = 1, steps: Int = 5)
        -> (EncodeJob) async throws -> URL
    {
        return { job in
            for _ in 0..<steps {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: stepMs * 1_000_000)
            }
            return job.defaultOutputURL
        }
    }

    /// Block until `predicate` returns true or `timeoutSec` elapses.
    /// Spins via `Task.sleep` so MainActor work can interleave.
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        timeoutSec: Double = 2.0,
        pollMs: UInt64 = 2
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
        }
    }

    // MARK: - (1) addJobs inherits current default

    func testAddJobsInheritsCurrentDefault() async {
        let queue = EncodeQueue()
        queue.defaultTier = .hq
        queue.defaultAlpha = .withAlpha
        queue.addJobs(urls: [makeURL("a")])
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].format, .yg10,
                       "HQ + with alpha must add as YG10")

        // Flipping defaults later must NOT touch existing jobs.
        queue.defaultTier = .normal
        queue.defaultAlpha = .withoutAlpha
        queue.addJobs(urls: [makeURL("b")])
        XCTAssertEqual(queue.jobs.count, 2)
        XCTAssertEqual(queue.jobs[0].format, .yg10,
                       "existing job format must not change when defaults flip")
        XCTAssertEqual(queue.jobs[1].format, .dxt1,
                       "Normal + no alpha must add as DXT1")
    }

    // MARK: - (2) Per-row override sticks

    func testPerRowOverrideDoesNotPropagate() {
        let queue = EncodeQueue()
        queue.defaultTier = .normal
        queue.defaultAlpha = .withoutAlpha   // DXT1
        queue.addJobs(urls: [makeURL("a")])
        XCTAssertEqual(queue.jobs[0].format, .dxt1)

        // Override row 0 to YG10 manually.
        queue.jobs[0].format = .yg10

        // Flip globals to DXT5; row 0 stays YG10.
        queue.defaultTier = .normal
        queue.defaultAlpha = .withAlpha   // DXT5
        XCTAssertEqual(queue.jobs[0].format, .yg10,
                       "per-row format must survive default mutations")

        // New row inherits the new defaults.
        queue.addJobs(urls: [makeURL("b")])
        XCTAssertEqual(queue.jobs[1].format, .dxt5)
    }

    // MARK: - (3) Cancel a queued job

    func testCancelQueuedJob() async {
        let queue = EncodeQueue()
        queue._testEncodeJobHook = slowStubHook(stepMs: 1, steps: 10)
        queue.addJobs(urls: [makeURL("a"), makeURL("b"), makeURL("c")])
        let middleID = queue.jobs[1].id

        // Cancel the middle job before encodeAll() starts.
        queue.cancel(id: middleID)
        XCTAssertEqual(queue.jobs[1].status, .failed)
        XCTAssertEqual(queue.jobs[1].errorMessage, "Cancelled")

        // Run the rest of the queue — the cancelled row should
        // remain .failed; the others should encode normally.
        queue.encodeAll()
        await waitUntil({ !queue.isEncoding }, timeoutSec: 3.0)
        XCTAssertEqual(queue.jobs[0].status, .done)
        XCTAssertEqual(queue.jobs[1].status, .failed,
                       "cancelled queued job must remain failed")
        XCTAssertEqual(queue.jobs[1].errorMessage, "Cancelled")
        XCTAssertEqual(queue.jobs[2].status, .done)
    }

    // MARK: - (4) Cancel all during encode

    func testCancelAllDuringEncode() async {
        let queue = EncodeQueue()
        // Longer steps so cancelAll() definitely lands while a job
        // is mid-flight.
        queue._testEncodeJobHook = slowStubHook(stepMs: 5, steps: 20)
        queue.addJobs(urls: [makeURL("a"), makeURL("b"), makeURL("c")])
        queue.encodeAll()

        // Wait for job 0 to start.
        await waitUntil({ queue.jobs[0].status == .encoding },
                        timeoutSec: 2.0)
        XCTAssertEqual(queue.jobs[0].status, .encoding,
                       "job 0 should be encoding before cancelAll")

        queue.cancelAll()
        await waitUntil({ !queue.isEncoding }, timeoutSec: 3.0)

        XCTAssertEqual(queue.jobs[0].status, .failed,
                       "in-flight job must end .failed after cancelAll")
        XCTAssertEqual(queue.jobs[0].errorMessage, "Cancelled")
        XCTAssertEqual(queue.jobs[1].status, .failed,
                       "remaining queued jobs must be marked .failed")
        XCTAssertEqual(queue.jobs[1].errorMessage, "Cancelled")
        XCTAssertEqual(queue.jobs[2].status, .failed)
        XCTAssertEqual(queue.jobs[2].errorMessage, "Cancelled")
    }

    // MARK: - (5) Remove a job

    func testRemoveJob() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [makeURL("a"), makeURL("b"), makeURL("c")])
        XCTAssertEqual(queue.jobs.count, 3)
        let middleID = queue.jobs[1].id
        queue.removeJob(id: middleID)
        XCTAssertEqual(queue.jobs.count, 2)
        XCTAssertFalse(queue.jobs.contains { $0.id == middleID })
    }

    /// Removing an actively-encoding job is a no-op (caller must
    /// cancel first); guards against orphaning the current Task.
    func testRemoveJobDuringEncodeIsNoOp() async {
        let queue = EncodeQueue()
        queue._testEncodeJobHook = slowStubHook(stepMs: 5, steps: 20)
        queue.addJobs(urls: [makeURL("a")])
        queue.encodeAll()
        await waitUntil({ queue.jobs.first?.status == .encoding },
                        timeoutSec: 2.0)
        let id = queue.jobs[0].id
        queue.removeJob(id: id)
        XCTAssertEqual(queue.jobs.count, 1,
                       "removeJob during encode must be a no-op")
        queue.cancelAll()
        await waitUntil({ !queue.isEncoding }, timeoutSec: 3.0)
    }

    // MARK: - (6) Clear completed

    func testClearCompleted() {
        let queue = EncodeQueue()
        queue.addJobs(urls: [makeURL("a"), makeURL("b"), makeURL("c")])
        // Mark rows 0 and 2 terminal via direct mutation (test-only
        // setter; production path is the encode loop).
        queue.jobs[0].status = .done
        queue.jobs[2].status = .failed
        queue.jobs[2].errorMessage = "Simulated failure"
        XCTAssertEqual(queue.jobs.count, 3)

        queue.clearCompleted()
        XCTAssertEqual(queue.jobs.count, 1)
        XCTAssertEqual(queue.jobs[0].status, .queued,
                       "the queued row must survive clearCompleted")
    }

    // MARK: - (7) Phase 7A Finding 5 — cancel/error deletes partial output

    /// Source URL that yields a writable `defaultOutputURL` in a real
    /// (writable) directory so we can assert the cleanup actually
    /// removed a file from disk.
    private func makeSourceInTempDir(name: String) throws -> URL {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-f5-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let src = tmpDir.appendingPathComponent("\(name).mov")
        // A non-empty source file so the queue's job-add doesn't trip on
        // file-not-exists down the line. Content doesn't matter for the
        // test hook path.
        try Data([0xAB, 0xCD]).write(to: src)
        return src
    }

    /// CancellationError thrown mid-encode must delete the partial
    /// output file written by the (now-aborted) writer. Pre-fix
    /// behavior: file lingered. Post-fix behavior: cleaned up.
    func testCancelDeletesPartialOutput() async throws {
        let src = try makeSourceInTempDir(name: "cancel-test")
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        let queue = EncodeQueue()
        queue.addJobs(urls: [src])
        let expectedOut = queue.jobs[0].defaultOutputURL

        // Stub the encode: write a "partial output" file to the expected
        // path (simulating DXVMOVWriter's ftyp/wide/mdat header + some
        // mdat data), then throw CancellationError. The queue's catch
        // block is what we're testing.
        queue._testEncodeJobHook = { job in
            try Data("ftyp/wide/mdat partial bytes".utf8).write(to: job.defaultOutputURL)
            throw CancellationError()
        }

        queue.encodeAll()
        await waitUntil({ !queue.isEncoding }, timeoutSec: 3.0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedOut.path),
                       "partial output must be deleted on CancellationError")
        XCTAssertEqual(queue.jobs[0].status, .failed)
        XCTAssertEqual(queue.jobs[0].errorMessage, "Cancelled")
    }

    /// Non-cancellation throw (e.g. a decode error) must also delete
    /// the partial output. Covers the catch-Error block specifically.
    func testFailureDeletesPartialOutput() async throws {
        let src = try makeSourceInTempDir(name: "fail-test")
        defer { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        let queue = EncodeQueue()
        queue.addJobs(urls: [src])
        let expectedOut = queue.jobs[0].defaultOutputURL

        queue._testEncodeJobHook = { job in
            try Data("partial bytes".utf8).write(to: job.defaultOutputURL)
            throw NSError(domain: "TestDomain", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: "simulated decode error"])
        }

        queue.encodeAll()
        await waitUntil({ !queue.isEncoding }, timeoutSec: 3.0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedOut.path),
                       "partial output must be deleted on any thrown error")
        XCTAssertEqual(queue.jobs[0].status, .failed)
        XCTAssertNotNil(queue.jobs[0].errorMessage)
        XCTAssertNotEqual(queue.jobs[0].errorMessage, "Cancelled",
                          "non-cancel error must not be labelled 'Cancelled'")
    }
}
