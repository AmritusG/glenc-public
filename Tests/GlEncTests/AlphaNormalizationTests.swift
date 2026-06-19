/*
 * AlphaNormalizationTests — v0.9.2 Phase B.
 *
 * Validates the shared alpha-normalization helper extracted from
 * DXT5Encoder's Phase B Pass B logic. DXT5 byte-identity is
 * covered separately by DXT5EncoderTests — this file targets the
 * helper's pure-function surface.
 */

import XCTest
import CoreGraphics
@testable import GlEncCore

final class AlphaNormalizationTests: XCTestCase {

    // MARK: - mode(for:) decision table

    func testMode_premultipliedFirst_unpremultiply() throws {
        XCTAssertEqual(try AlphaNormalization.mode(for: .premultipliedFirst),
                       .unpremultiply)
    }

    func testMode_premultipliedLast_unpremultiply() throws {
        XCTAssertEqual(try AlphaNormalization.mode(for: .premultipliedLast),
                       .unpremultiply)
    }

    func testMode_first_straightThrough() throws {
        XCTAssertEqual(try AlphaNormalization.mode(for: .first),
                       .straightThrough)
    }

    func testMode_last_straightThrough() throws {
        XCTAssertEqual(try AlphaNormalization.mode(for: .last),
                       .straightThrough)
    }

    func testMode_noneSkipFirst_forceOpaque() throws {
        XCTAssertEqual(try AlphaNormalization.mode(for: .noneSkipFirst),
                       .forceOpaque)
    }

    func testMode_noneSkipLast_forceOpaque() throws {
        XCTAssertEqual(try AlphaNormalization.mode(for: .noneSkipLast),
                       .forceOpaque)
    }

    func testMode_none_forceOpaque() throws {
        XCTAssertEqual(try AlphaNormalization.mode(for: .none),
                       .forceOpaque)
    }

    func testMode_alphaOnly_throws() {
        XCTAssertThrowsError(try AlphaNormalization.mode(for: .alphaOnly)) { e in
            guard case AlphaNormalization.Error.unsupportedAlphaInfo = e else {
                XCTFail("expected unsupportedAlphaInfo, got \(e)")
                return
            }
        }
    }

    // MARK: - sourceHasAlpha

    func testSourceHasAlpha() {
        XCTAssertFalse(AlphaNormalization.forceOpaque.sourceHasAlpha)
        XCTAssertTrue(AlphaNormalization.straightThrough.sourceHasAlpha)
        XCTAssertTrue(AlphaNormalization.unpremultiply.sourceHasAlpha)
    }

    // MARK: - apply: forceOpaque

    func testApply_forceOpaque_writesAlphaAs255() {
        let (r, g, b, a) = AlphaNormalization.forceOpaque
            .apply(r: 10, g: 20, b: 30, a: 0)
        XCTAssertEqual(r, 10)
        XCTAssertEqual(g, 20)
        XCTAssertEqual(b, 30)
        XCTAssertEqual(a, 255, "forceOpaque must write α=255 regardless of source α")
    }

    // MARK: - apply: straightThrough

    func testApply_straightThrough_passesAllChannelsUnchanged() {
        let (r, g, b, a) = AlphaNormalization.straightThrough
            .apply(r: 100, g: 150, b: 200, a: 128)
        XCTAssertEqual([r, g, b, a], [100, 150, 200, 128])
    }

    // MARK: - apply: unpremultiply

    /// α=0 maps the pixel to all-zero (RGB and α). Matches the prior
    /// DXT5Encoder inline behavior — a transparent pixel has no
    /// recoverable color.
    func testApply_unpremultiply_zeroAlpha_writesAllZeros() {
        let (r, g, b, a) = AlphaNormalization.unpremultiply
            .apply(r: 128, g: 128, b: 128, a: 0)
        XCTAssertEqual([r, g, b, a], [0, 0, 0, 0])
    }

    /// α=255 (fully opaque, premultiplied is a no-op): R'=R etc.
    func testApply_unpremultiply_fullAlpha_isIdentity() {
        let (r, g, b, a) = AlphaNormalization.unpremultiply
            .apply(r: 200, g: 100, b: 50, a: 255)
        // R' = round(R * 255 / 255 + 0) = R. Integer math: (200 * 255 + 127) / 255 = 200.
        XCTAssertEqual([r, g, b, a], [200, 100, 50, 255])
    }

    /// α=128, R=64 → R' = round(64 * 255 / 128) = round(127.5) = 128
    /// with the +α/2 rounding bias: (64*255 + 64) / 128 = (16320 + 64) / 128
    /// = 16384 / 128 = 128. Verified.
    func testApply_unpremultiply_halfAlpha_dividesByAlpha() {
        let (r, g, b, a) = AlphaNormalization.unpremultiply
            .apply(r: 64, g: 32, b: 16, a: 128)
        // R: (64*255 + 64) / 128 = 16384/128 = 128.
        // G: (32*255 + 64) / 128 = (8160 + 64) / 128 = 8224 / 128 = 64.25 → 64.
        // B: (16*255 + 64) / 128 = (4080 + 64) / 128 = 4144 / 128 = 32.375 → 32.
        XCTAssertEqual([r, g, b, a], [128, 64, 32, 128])
    }

    /// Saturation: if premultiplied input has R > α (shouldn't
    /// happen in well-formed input, but clamping protects against
    /// it), R' clamps to 255 rather than overflowing UInt8.
    func testApply_unpremultiply_clampsToMax255() {
        let (r, _, _, _) = AlphaNormalization.unpremultiply
            .apply(r: 200, g: 0, b: 0, a: 1)  // ridiculous: R=200, α=1
        XCTAssertEqual(r, 255, "must clamp to 255 when (R*255 + α/2)/α exceeds 255")
    }

    /// Per-channel independence: only R differs in input.
    func testApply_unpremultiply_perChannelIndependent() {
        let p1 = AlphaNormalization.unpremultiply
            .apply(r: 100, g: 50, b: 25, a: 200)
        let p2 = AlphaNormalization.unpremultiply
            .apply(r: 100, g: 100, b: 25, a: 200)
        XCTAssertEqual(p1.r, p2.r)
        XCTAssertNotEqual(p1.g, p2.g)
        XCTAssertEqual(p1.b, p2.b)
        XCTAssertEqual(p1.a, p2.a)
    }
}
