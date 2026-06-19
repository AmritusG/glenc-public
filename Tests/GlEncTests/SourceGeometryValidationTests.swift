/*
 * SourceGeometryValidationTests.swift — Hardening Fix-Brief 1.
 *
 * Regression coverage for the source-input validation guard at the reader
 * trust boundary (`validateSourceGeometry` + the three reader inits).
 * Each malformed-input mode asserts a clean thrown `SourceReaderError`,
 * NOT a crash / precondition trap / wrong-but-successful output.
 *
 * Two layers:
 *   1. Direct unit tests on `validateSourceGeometry` — one per failure
 *      mode (zero/negative/tiny/oversized dims, oversized area, zero/
 *      NaN/∞ fps, NaN/∞/negative duration). These are the canonical
 *      per-mode assertions; they need no file I/O.
 *   2. Reader-boundary integration tests — materialize a genuinely
 *      malformed DXV `.mov` from the fuzz corpus and prove the guard
 *      fires inside `DxvSourceReader.init` (so the validation is wired
 *      in, not just unit-correct).
 *
 * Retires audit findings 1.1, 1.2, 2.1, 4.1, 4.2, 4.3, 4.4, 4.6, 5.1,
 * C.1, C.2 (audit top-10 items 1, 2, 4, 6, 9). Note 4.6/C.2 were resolved
 * during diagnosis to be a force-unwrap CRASH (empty DXT decode buffer at
 * CPURender.cgImageFromDXT) on tiny/zero height — not the heap-overwrite /
 * silent-wrong-output the audit hypothesized; the guard subsumes both.
 */

import XCTest
import Foundation
@testable import GlEncCore

final class SourceGeometryValidationTests: XCTestCase {

    // MARK: - Assertion helpers

    private func expectSourceError(
        _ body: () throws -> Void,
        isExpected: (SourceReaderError) -> Bool,
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            try body()
            XCTFail("expected SourceReaderError, none thrown. \(message)", file: file, line: line)
        } catch let e as SourceReaderError {
            XCTAssertTrue(isExpected(e), "wrong SourceReaderError case: \(e). \(message)",
                          file: file, line: line)
        } catch {
            XCTFail("expected SourceReaderError, got \(type(of: error)): \(error). \(message)",
                    file: file, line: line)
        }
    }

    private func isInvalidDims(_ e: SourceReaderError) -> Bool {
        if case .sourceDimensionsInvalid = e { return true }; return false
    }
    private func isTooLarge(_ e: SourceReaderError) -> Bool {
        if case .sourceDimensionsTooLarge = e { return true }; return false
    }
    private func isFrameTooLarge(_ e: SourceReaderError) -> Bool {
        if case .sourceFrameTooLarge = e { return true }; return false
    }
    private func isBadFPS(_ e: SourceReaderError) -> Bool {
        if case .sourceFrameRateInvalid = e { return true }; return false
    }
    private func isBadDuration(_ e: SourceReaderError) -> Bool {
        if case .sourceDurationInvalid = e { return true }; return false
    }
    /// readNextFrame wraps the zero-block throw as `.dxvDecodeFailed`
    /// (idx:, underlying: .dxvZeroBlockGeometry).
    private func isDecodeFailed(_ e: SourceReaderError) -> Bool {
        if case .dxvDecodeFailed = e { return true }; return false
    }

    // MARK: - Valid / boundary geometry passes

    func testValidGeometryPasses() {
        XCTAssertNoThrow(try validateSourceGeometry(width: 1920, height: 1080, fps: 30, duration: 60))
    }

    func testMinDimensionBoundaryPasses() {
        // Fix-Brief 1-narrow — the floor is now "positive" (≥ 1), not 4.
        // 1×1 passes the geometry guard; sub-4-height DXT decode is guarded
        // separately at the DxvSourceReader DXT site, not by this floor.
        XCTAssertNoThrow(try validateSourceGeometry(width: 1, height: 1, fps: 1, duration: 0))
    }

    // Fix-Brief 1-narrow — the validated-removed 4-px/round-to-4 alignment
    // must NOT be re-imposed: a non-4-aligned source passes the guard.
    func testNonFourAlignedDimsPassGeometryGuard() {
        XCTAssertNoThrow(try validateSourceGeometry(width: 1922, height: 1080, fps: 30, duration: 5))
    }

    // Width 1/2/3 with adequate height never crashed (paddedW pads to 16);
    // the narrowed floor must accept it.
    func testSubFourWidthPassesGeometryGuard() {
        XCTAssertNoThrow(try validateSourceGeometry(width: 2, height: 1080, fps: 30, duration: 5))
    }

    func testMaxDimensionWithSmallAreaPasses() {
        // 65535×4 = 262,140 px ≤ 16384² — at the per-side cap, under the area cap.
        XCTAssertNoThrow(try validateSourceGeometry(width: 65535, height: 4, fps: 30, duration: 1))
    }

    func testNtscFpsPasses() {
        XCTAssertNoThrow(try validateSourceGeometry(width: 1920, height: 1080,
                                                    fps: 30000.0 / 1001.0, duration: 12.0))
    }

    // MARK: - Dimension failure modes

    func testZeroDimensionsThrowInvalid() {
        expectSourceError({ try validateSourceGeometry(width: 0, height: 0, fps: 30, duration: 1) },
                          isExpected: isInvalidDims)
    }

    func testNegativeWidthThrowsInvalid() {
        expectSourceError({ try validateSourceGeometry(width: -5, height: 1080, fps: 30, duration: 1) },
                          isExpected: isInvalidDims)
    }

    func testNegativeHeightThrowsInvalid() {
        expectSourceError({ try validateSourceGeometry(width: 1920, height: -1, fps: 30, duration: 1) },
                          isExpected: isInvalidDims)
    }

    // Fix-Brief 1-narrow — tiny height (the audit 4.6/C.2 crash trigger) no
    // longer fails the GEOMETRY guard (the blanket min-4 is gone). It now
    // passes validateSourceGeometry and is caught at the DXV DXT decode
    // site instead (see testMalformedDXVTinyHeightThrowsAtDecode below).
    func testTinyHeightPassesGeometryGuard() {
        XCTAssertNoThrow(try validateSourceGeometry(width: 1920, height: 2, fps: 30, duration: 1))
    }

    func testTinyOddHeightPassesGeometryGuard() {
        XCTAssertNoThrow(try validateSourceGeometry(width: 1920, height: 3, fps: 30, duration: 1))
    }

    // Audit 5.1 / 2.1 — dimension beyond the writer's UInt16 structural cap.
    func testOversizedWidthThrowsTooLarge() {
        expectSourceError({ try validateSourceGeometry(width: 70000, height: 1080, fps: 30, duration: 1) },
                          isExpected: isTooLarge)
    }

    func testOversizedHeightThrowsTooLarge() {
        expectSourceError({ try validateSourceGeometry(width: 1920, height: 70000, fps: 30, duration: 1) },
                          isExpected: isTooLarge)
    }

    // Audit 5.1 — in-range per side, but area would OOM the encoder buffer.
    func testHugeAreaThrowsFrameTooLarge() {
        expectSourceError({ try validateSourceGeometry(width: 65535, height: 65535, fps: 30, duration: 1) },
                          isExpected: isFrameTooLarge)
    }

    // MARK: - Frame-rate failure modes (audit 4.2 — fps=0 → writer ÷0)

    func testZeroFPSThrows() {
        expectSourceError({ try validateSourceGeometry(width: 1920, height: 1080, fps: 0, duration: 1) },
                          isExpected: isBadFPS)
    }

    func testNegativeFPSThrows() {
        expectSourceError({ try validateSourceGeometry(width: 1920, height: 1080, fps: -30, duration: 1) },
                          isExpected: isBadFPS)
    }

    func testNaNFPSThrows() {
        expectSourceError({ try validateSourceGeometry(width: 1920, height: 1080, fps: .nan, duration: 1) },
                          isExpected: isBadFPS)
    }

    func testInfiniteFPSThrows() {
        expectSourceError({ try validateSourceGeometry(width: 1920, height: 1080, fps: .infinity, duration: 1) },
                          isExpected: isBadFPS)
    }

    // MARK: - Duration failure modes (audit 4.1 — Int(NaN) trap)

    func testNaNDurationThrows() {
        expectSourceError({ try validateSourceGeometry(width: 1920, height: 1080, fps: 30, duration: .nan) },
                          isExpected: isBadDuration)
    }

    func testInfiniteDurationThrows() {
        expectSourceError({ try validateSourceGeometry(width: 1920, height: 1080, fps: 30, duration: .infinity) },
                          isExpected: isBadDuration)
    }

    func testNegativeDurationThrows() {
        expectSourceError({ try validateSourceGeometry(width: 1920, height: 1080, fps: 30, duration: -1) },
                          isExpected: isBadDuration)
    }

    // MARK: - Reader-boundary integration via the fuzz corpus

    private func assertDxvReaderThrows(
        _ mutation: MalformedDXVFixtures.Mutation,
        isExpected: (SourceReaderError) -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: MalformedDXVFixtures.referenceURL.path),
                          "fuzz-corpus reference DXV not present: \(MalformedDXVFixtures.referenceURL.path)")
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-fuzz-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }
        try MalformedDXVFixtures.make(mutation, into: dest)
        expectSourceError({ _ = try DxvSourceReader(url: dest) },
                          isExpected: isExpected,
                          "malformed DXV \(mutation) must throw at the reader boundary",
                          file: file, line: line)
    }

    /// Like `assertDxvReaderThrows`, but the geometry passes the init guard
    /// and the failure is expected on the FIRST frame read (the narrowed
    /// zero-block DXT guard inside `decodeFrameRGBA`).
    private func assertDxvReadNextFrameThrows(
        _ mutation: MalformedDXVFixtures.Mutation,
        isExpected: (SourceReaderError) -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: MalformedDXVFixtures.referenceURL.path),
                          "fuzz-corpus reference DXV not present: \(MalformedDXVFixtures.referenceURL.path)")
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-fuzz-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }
        try MalformedDXVFixtures.make(mutation, into: dest)
        // Init must SUCCEED now (geometry guard accepts h ≥ 1)…
        let reader = try DxvSourceReader(url: dest)
        // …and the zero-block DXT decode must fail cleanly on frame 0.
        expectSourceError({ _ = try reader.readNextFrame() },
                          isExpected: isExpected,
                          "malformed DXV \(mutation) must throw at the DXT decode site",
                          file: file, line: line)
    }

    func testMalformedDXVZeroDimsThrowsAtReader() throws {
        // 0×0 still fails the geometry guard at init (non-positive).
        try assertDxvReaderThrows(.dimensions(width: 0, height: 0), isExpected: isInvalidDims)
    }

    func testMalformedDXVTinyHeightThrowsAtDecode() throws {
        // 1920×2: init succeeds (h ≥ 1), zero-block DXT decode throws on read.
        try assertDxvReadNextFrameThrows(.dimensions(width: 1920, height: 2), isExpected: isDecodeFailed)
    }

    func testMalformedDXVHugeAreaThrowsAtReader() throws {
        try assertDxvReaderThrows(.dimensions(width: 65535, height: 65535), isExpected: isFrameTooLarge)
    }
}
