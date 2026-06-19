/*
 * Checkerboard scope — fitted-rect math for the "behind video only"
 * preference. Pure function (no UI), so unit-testable: fill-viewport
 * returns bounds; behind-video returns the aspect-fit video rect;
 * missing/zero dims fall back to bounds.
 */
import XCTest
import AVFoundation
@testable import GlEnc

@MainActor
final class CheckerboardScopeTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 800)

    func testFillViewport_ReturnsBounds_RegardlessOfDims() {
        let r = PreviewLayerHostingNSView.checkerboardFrame(
            scope: .fillViewport, sourceWidth: 1920, sourceHeight: 1080, bounds: bounds)
        XCTAssertEqual(r, bounds)
    }

    func testBehindVideo_16x9_InSquareBounds_IsLetterboxedFit() {
        let r = PreviewLayerHostingNSView.checkerboardFrame(
            scope: .behindVideoOnly, sourceWidth: 1920, sourceHeight: 1080, bounds: bounds)
        let expected = AVMakeRect(aspectRatio: CGSize(width: 1920, height: 1080), insideRect: bounds)
        XCTAssertEqual(r, expected)
        // 16:9 in 800×800 → full width 800, height 450, centred (y=175).
        XCTAssertEqual(r.width, 800, accuracy: 0.5)
        XCTAssertEqual(r.height, 450, accuracy: 0.5)
        XCTAssertEqual(r.minY, 175, accuracy: 0.5)
        XCTAssertLessThan(r.height, bounds.height, "must letterbox (bars present)")
    }

    func testBehindVideo_SquareSource_FillsSquareBounds_NoBars() {
        let r = PreviewLayerHostingNSView.checkerboardFrame(
            scope: .behindVideoOnly, sourceWidth: 512, sourceHeight: 512, bounds: bounds)
        XCTAssertEqual(r, bounds, "matched aspect → no letterbox, fills bounds")
    }

    func testBehindVideo_ZeroDims_FallsBackToBounds() {
        let r0 = PreviewLayerHostingNSView.checkerboardFrame(
            scope: .behindVideoOnly, sourceWidth: 0, sourceHeight: 0, bounds: bounds)
        XCTAssertEqual(r0, bounds, "no source dims → never leave the checker unframed")
        let rEmptyBounds = PreviewLayerHostingNSView.checkerboardFrame(
            scope: .behindVideoOnly, sourceWidth: 1920, sourceHeight: 1080, bounds: .zero)
        XCTAssertEqual(rEmptyBounds, .zero, "zero bounds → bounds fallback")
    }

    func testDefaultScopeIsFillViewport() {
        XCTAssertEqual(AppSettings.CheckerboardScope.fillViewport.rawValue, "fillViewport")
        XCTAssertEqual(AppSettings.CheckerboardScope.allCases.count, 2)
    }
}
