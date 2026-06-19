/*
 * EncodeJobCropRectTests — Crop Release Phase B.
 *
 * Regression coverage for the additive `EncodeJob.cropRect: CGRect?`
 * field:
 *   - the init default is nil (no crop for newly-constructed jobs),
 *   - the new field participates in EncodeJob's synthesized Equatable
 *     conformance,
 *   - an explicit `cropRect: nil` is indistinguishable from the
 *     unnamed-argument default.
 *
 * Note on `id`: `EncodeJob.id` is a fresh `UUID()` per init, so two
 * SEPARATELY-constructed jobs are never `==` (the synthesized
 * Equatable compares `id` too). Equality is therefore exercised via
 * a struct copy — `var b = a` copies every stored property including
 * `id` — which isolates `cropRect` as the only field under test.
 */

import XCTest
import Foundation
import CoreGraphics
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class EncodeJobCropRectTests: XCTestCase {

    func testCropRectDefaultIsNilAndParticipatesInEquatable() {
        let url = URL(fileURLWithPath: "/tmp/probe.mov")

        // Baseline: a job and its struct copy are equal — every
        // stored property (including the generated `id`) matches.
        let base = EncodeJob(sourceURL: url)
        var copy = base
        XCTAssertEqual(base, copy,
                       "A struct copy must equal its original")

        // The init default for cropRect is nil. Assigning an explicit
        // nil to the copy leaves the two equal — proving the
        // unnamed-argument default is itself nil.
        XCTAssertNil(base.cropRect,
                     "EncodeJob default cropRect must be nil")
        copy.cropRect = nil
        XCTAssertEqual(base, copy,
                       "Explicit cropRect = nil must equal the unnamed-arg default")

        // Differing only in cropRect makes the two unequal — the new
        // field participates in the synthesized Equatable conformance.
        copy.cropRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNotEqual(base, copy,
                          "Jobs differing only in cropRect must be unequal")
    }
}
