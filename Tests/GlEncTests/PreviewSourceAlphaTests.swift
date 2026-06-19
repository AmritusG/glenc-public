/*
 * PreviewSourceAlphaTests — v1.0.x preview source-alpha gate.
 *
 * Covers the two pure FourCC/variant → has-alpha mappings that drive
 * `PreviewPlayerModel.previewSourceHasAlpha`, which in turn gates the
 * preview transparency checkerboard across ALL THREE backends (HAP /
 * DXV / AV). The mappings are source-truth: a property of the
 * previewed file, independent of the selected output codec.
 *
 * The AV branch (ProRes 4444 → alpha) flows through
 * `EncodeJob.probeSourceAlpha`, which is exercised elsewhere; here we
 * lock the HAP and DXV synchronous mappings against drift.
 */

import XCTest
import GlancePlayback
@testable import GlEnc

@MainActor
final class PreviewSourceAlphaTests: XCTestCase {

    func testHapFourCCAlphaMapping() {
        // Alpha-carrying HAP variants.
        XCTAssertTrue(PreviewPlayerModel.hapFourCCHasAlpha("Hap5"), "Hap5 is RGBA (DXT5) → alpha")
        XCTAssertTrue(PreviewPlayerModel.hapFourCCHasAlpha("HapM"), "HapM wraps HapY+HapA → alpha")
        XCTAssertTrue(PreviewPlayerModel.hapFourCCHasAlpha("HapA"), "HapA is alpha-only → alpha")
        // Opaque HAP variants.
        XCTAssertFalse(PreviewPlayerModel.hapFourCCHasAlpha("Hap1"), "Hap1 is RGB (DXT1) → opaque")
        XCTAssertFalse(PreviewPlayerModel.hapFourCCHasAlpha("HapY"), "HapY is scaled-YCoCg → opaque")
        // Unknown / non-HAP FourCC defaults to opaque.
        XCTAssertFalse(PreviewPlayerModel.hapFourCCHasAlpha("avc1"))
    }

    func testDXVVariantAlphaMapping() {
        XCTAssertTrue(PreviewPlayerModel.dxvVariantHasAlpha(.dxt5), "DXT5 carries alpha")
        XCTAssertTrue(PreviewPlayerModel.dxvVariantHasAlpha(.yg10), "YG10 carries alpha")
        XCTAssertFalse(PreviewPlayerModel.dxvVariantHasAlpha(.dxt1), "DXT1 is opaque")
        XCTAssertFalse(PreviewPlayerModel.dxvVariantHasAlpha(.ycg6), "YCG6 is opaque")
    }

    func testPreviewSourceHasAlphaDefaultsFalse() {
        // A freshly-constructed model with nothing loaded must not show
        // the checkerboard.
        let model = PreviewPlayerModel()
        XCTAssertFalse(model.previewSourceHasAlpha)
    }
}
