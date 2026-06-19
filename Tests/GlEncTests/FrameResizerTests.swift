/*
 * FrameResizerTests — Resize Release Phase D.
 *
 * Property tests for the FrameResizer helper. Scaling correctness is
 * hard to assert with a pixel-perfect oracle; instead these tests
 * check PROPERTIES:
 *   - Output dimensions exactly match the requested target.
 *   - Equal-dims short-circuits to the input frame (no-op).
 *   - Solid-color frames stay solid through every filter.
 *   - Nearest preserves exact source pixel values (no smoothing).
 *   - Auto's filter-dispatch matches the explicit equivalent
 *     (downscale .auto == .lanczos; upscale .auto == .bilinear).
 *   - A simple 2-region pattern downscaled keeps its dominant colors
 *     in the corresponding output regions.
 *   - Zero/negative target throws rather than crashes.
 *   - 1080p-class realistic size (the v0.9.1 H.3 standing rule).
 *
 * Every expected value is derived from the spec or first principles,
 * never pasted from emitted output (standing rule).
 */

import XCTest
import Foundation
import CoreVideo
import CoreMedia
import CoreGraphics
@testable import GlEncCore

final class FrameResizerTests: XCTestCase {

    // MARK: - Synthesis

    /// Build a BGRA PixelFrame at `(width, height)` filled by
    /// `pixelFn(x, y) -> (B, G, R, A)`.
    private func makeFrame(
        width: Int, height: Int,
        alphaInfo: CGImageAlphaInfo = .last,
        pixelFn: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "FrameResizerTest", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                let (b, g, r, a) = pixelFn(x, y)
                p[0] = b; p[1] = g; p[2] = r; p[3] = a
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero,
                          alphaInfo: alphaInfo)
    }

    private func solidFrame(width: Int, height: Int,
                            b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 0xFF) throws -> PixelFrame {
        try makeFrame(width: width, height: height) { _, _ in (b, g, r, a) }
    }

    private func readPixel(_ f: PixelFrame, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(f.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(f.pixelBuffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(f.pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(f.pixelBuffer)
        let p = base.advanced(by: y * bpr + x * 4)
        return (p[0], p[1], p[2], p[3])
    }

    /// Slurp all pixels into a tight BGRA byte array (one byte per
    /// channel). Used for byte-equality comparisons between two
    /// resize results.
    private func bytes(_ f: PixelFrame) -> [UInt8] {
        CVPixelBufferLockBaseAddress(f.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(f.pixelBuffer, .readOnly) }
        let w = f.width, h = f.height
        let base = CVPixelBufferGetBaseAddress(f.pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(f.pixelBuffer)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let src = base.advanced(by: y * bpr)
            for x in 0..<(w * 4) {
                out[y * w * 4 + x] = src[x]
            }
        }
        return out
    }

    // MARK: - 1. Output dimensions

    /// Downscale, upscale, non-square aspect change, mixed direction.
    /// Each must produce a frame whose width × height matches the
    /// target exactly.
    func testOutputDimensionsMatchTarget() throws {
        let src = try solidFrame(width: 1920, height: 1080,
                                 b: 0x80, g: 0x40, r: 0xC0)
        let cases: [(Int, Int, ResizeQuality)] = [
            (1280, 720, .nearest),     // downscale
            (1280, 720, .bilinear),    // downscale
            (1280, 720, .lanczos),     // downscale
            (1280, 720, .auto),        // downscale auto
            (3840, 2160, .nearest),    // upscale
            (3840, 2160, .bilinear),   // upscale
            (3840, 2160, .lanczos),    // upscale
            (3840, 2160, .auto),       // upscale auto
            (720, 1280, .auto),        // mixed (portrait aspect)
            (1024, 1024, .auto),       // mixed (square)
            (4, 4, .nearest),          // extreme downscale
            (8, 4, .bilinear),         // tiny non-square
        ]
        for (w, h, q) in cases {
            let out = try FrameResizer.resize(src, toWidth: w, toHeight: h, quality: q)
            XCTAssertEqual(out.width, w,
                           "(\(w)×\(h), \(q)) output width must match target")
            XCTAssertEqual(out.height, h,
                           "(\(w)×\(h), \(q)) output height must match target")
        }
    }

    // MARK: - 2. Equal-dims short-circuits to input

    func testEqualDimensionsReturnsInputFrame() throws {
        let src = try makeFrame(width: 256, height: 256) { x, y in
            (UInt8((x + y) & 0xFF), UInt8((x * 2) & 0xFF), UInt8((y * 3) & 0xFF), 0xFF)
        }
        for q in ResizeQuality.allCases {
            let out = try FrameResizer.resize(src, toWidth: 256, toHeight: 256, quality: q)
            XCTAssertEqual(out.width, 256)
            XCTAssertEqual(out.height, 256)
            // The byte content must match exactly — no resize ran.
            XCTAssertEqual(bytes(out), bytes(src),
                           "equal-dims pass-through must preserve bytes (\(q))")
        }
    }

    // MARK: - 3. Solid-color preservation

    /// A solid-color frame has no edges. Any filter must produce a
    /// near-solid output (Lanczos's ringing is impossible without
    /// edge content). Asserting tight equality (max channel delta
    /// ≤ 1 LSB) covers integer-rounding inside the filter.
    func testSolidColorPreservedThroughAllFilters() throws {
        // Pick a non-trivial color (none of 0x00, 0xFF) so under/over-
        // shoot would be visible.
        let src = try solidFrame(width: 512, height: 288,
                                 b: 0x40, g: 0xA0, r: 0xC8, a: 0xFF)
        let targets: [(Int, Int)] = [
            (256, 144),   // downscale
            (1024, 576),  // upscale
            (300, 200),   // odd non-aspect
        ]
        for (tw, th) in targets {
            for q in ResizeQuality.allCases {
                let out = try FrameResizer.resize(src, toWidth: tw, toHeight: th, quality: q)
                // Sample a 3×3 grid of interior pixels — corners may
                // theoretically pick up boundary effects on some
                // filters, though for a solid color there's no edge.
                let positions = [(tw/4, th/4), (tw/2, th/2), (3*tw/4, 3*th/4)]
                for (x, y) in positions {
                    let (b, g, r, a) = readPixel(out, x: x, y: y)
                    XCTAssertLessThanOrEqual(abs(Int(b) - 0x40), 1,
                                             "(\(tw)×\(th), \(q)) pixel B drift at (\(x),\(y))")
                    XCTAssertLessThanOrEqual(abs(Int(g) - 0xA0), 1,
                                             "(\(tw)×\(th), \(q)) pixel G drift at (\(x),\(y))")
                    XCTAssertLessThanOrEqual(abs(Int(r) - 0xC8), 1,
                                             "(\(tw)×\(th), \(q)) pixel R drift at (\(x),\(y))")
                    XCTAssertLessThanOrEqual(abs(Int(a) - 0xFF), 1,
                                             "(\(tw)×\(th), \(q)) pixel A drift at (\(x),\(y))")
                }
            }
        }
    }

    // MARK: - 4. Nearest preserves exact source pixels

    /// Nearest-neighbour samples integer source pixels — output bytes
    /// must equal SOME source pixel exactly (no inter-pixel blending).
    /// Source is a checkerboard of two pure colors; every output pixel
    /// must be one of those two colors EXACTLY.
    func testNearestPreservesExactSourcePixels() throws {
        // 4×4 checkerboard, exaggerated for visibility.
        let red:  (UInt8, UInt8, UInt8, UInt8) = (0x00, 0x00, 0xFF, 0xFF) // BGRA
        let blue: (UInt8, UInt8, UInt8, UInt8) = (0xFF, 0x00, 0x00, 0xFF) // BGRA
        let src = try makeFrame(width: 4, height: 4) { x, y in
            ((x + y) % 2 == 0) ? red : blue
        }
        // Upscale and downscale through nearest.
        for (tw, th) in [(16, 16), (8, 8), (2, 2), (12, 7)] {
            let out = try FrameResizer.resize(src, toWidth: tw, toHeight: th,
                                              quality: .nearest)
            for y in 0..<th {
                for x in 0..<tw {
                    let p = readPixel(out, x: x, y: y)
                    XCTAssertTrue(p == red || p == blue,
                                  "(\(tw)×\(th)) nearest output at (\(x),\(y)) is \(p) — not red or blue (inter-pixel blend?)")
                }
            }
        }
    }

    // MARK: - 5. Auto resolves to the explicit equivalent

    /// .auto with a downscale target produces byte-identical output
    /// to .lanczos for the same dims. Q1+Q2 contract (downscale →
    /// Lanczos) made empirical through FrameResizer.
    func testAutoEquivalentToLanczosOnDownscale() throws {
        let src = try makeFrame(width: 256, height: 144) { x, y in
            (UInt8(x & 0xFF), UInt8(y & 0xFF), UInt8((x + y) & 0xFF), 0xFF)
        }
        let auto = try FrameResizer.resize(src, toWidth: 128, toHeight: 72, quality: .auto)
        let lanc = try FrameResizer.resize(src, toWidth: 128, toHeight: 72, quality: .lanczos)
        XCTAssertEqual(bytes(auto), bytes(lanc),
                       ".auto on downscale must produce the same bytes as .lanczos (Q1+Q2 contract)")
    }

    /// .auto with an upscale target produces byte-identical output
    /// to .bilinear for the same dims.
    func testAutoEquivalentToBilinearOnUpscale() throws {
        let src = try makeFrame(width: 128, height: 72) { x, y in
            (UInt8(x & 0xFF), UInt8(y & 0xFF), UInt8((x + y) & 0xFF), 0xFF)
        }
        let auto = try FrameResizer.resize(src, toWidth: 256, toHeight: 144, quality: .auto)
        let bili = try FrameResizer.resize(src, toWidth: 256, toHeight: 144, quality: .bilinear)
        XCTAssertEqual(bytes(auto), bytes(bili),
                       ".auto on upscale must produce the same bytes as .bilinear (Q1 contract)")
    }

    /// Mixed-direction (one axis shrinks, the other grows): the Phase B
    /// resolver classifies this as upscale (bilinear). Empirically
    /// match.
    func testAutoEquivalentToBilinearOnMixedDirection() throws {
        let src = try makeFrame(width: 200, height: 100) { x, y in
            (UInt8(x & 0xFF), UInt8(y & 0xFF), UInt8((x * y) & 0xFF), 0xFF)
        }
        let auto = try FrameResizer.resize(src, toWidth: 100, toHeight: 200, quality: .auto)
        let bili = try FrameResizer.resize(src, toWidth: 100, toHeight: 200, quality: .bilinear)
        XCTAssertEqual(bytes(auto), bytes(bili),
                       ".auto on mixed direction must produce the same bytes as .bilinear")
    }

    // MARK: - 6. 2-region pattern: corners keep dominant colors

    /// Half-red / half-blue pattern downscaled 4× — the left half of
    /// the output should still read mostly red; the right half mostly
    /// blue. "Mostly" via the dominant channel (R for red, B for blue).
    /// Tests that the spatial structure survives scaling.
    func testPatternDominantColorsSurviveDownscale() throws {
        let red:  (UInt8, UInt8, UInt8, UInt8) = (0x00, 0x00, 0xFF, 0xFF)
        let blue: (UInt8, UInt8, UInt8, UInt8) = (0xFF, 0x00, 0x00, 0xFF)
        // 256×64: red on left half, blue on right half. The boundary
        // is sharp.
        let src = try makeFrame(width: 256, height: 64) { x, _ in
            x < 128 ? red : blue
        }
        // Downscale 4× → 64×16. Sample inside each half-region,
        // away from the boundary, to skip the filter's transition
        // band.
        for q: ResizeQuality in [.nearest, .bilinear, .lanczos] {
            let out = try FrameResizer.resize(src, toWidth: 64, toHeight: 16, quality: q)
            // Left-half inner sample (x=8 = source x≈32, deep in red).
            let pLeft = readPixel(out, x: 8, y: 8)
            // pLeft should have R-dominance.
            XCTAssertGreaterThan(pLeft.2, pLeft.0,
                                 "(\(q)) left-half pixel must be R-dominant — got \(pLeft)")
            // Right-half inner sample (x=56 = source x≈224, deep in blue).
            let pRight = readPixel(out, x: 56, y: 8)
            // pRight should have B-dominance.
            XCTAssertGreaterThan(pRight.0, pRight.2,
                                 "(\(q)) right-half pixel must be B-dominant — got \(pRight)")
        }
    }

    // MARK: - 7. Invalid target throws

    func testZeroTargetWidthThrows() throws {
        let src = try solidFrame(width: 256, height: 256, b: 0, g: 0, r: 0)
        XCTAssertThrowsError(
            try FrameResizer.resize(src, toWidth: 0, toHeight: 256, quality: .auto)
        ) { err in
            guard case FrameResizerError.invalidTargetDimensions = err else {
                return XCTFail("expected invalidTargetDimensions, got \(err)")
            }
        }
    }

    func testZeroTargetHeightThrows() throws {
        let src = try solidFrame(width: 256, height: 256, b: 0, g: 0, r: 0)
        XCTAssertThrowsError(
            try FrameResizer.resize(src, toWidth: 256, toHeight: 0, quality: .auto)
        ) { err in
            guard case FrameResizerError.invalidTargetDimensions = err else {
                return XCTFail("expected invalidTargetDimensions, got \(err)")
            }
        }
    }

    func testNegativeTargetThrows() throws {
        let src = try solidFrame(width: 256, height: 256, b: 0, g: 0, r: 0)
        XCTAssertThrowsError(
            try FrameResizer.resize(src, toWidth: -10, toHeight: 256, quality: .auto)
        )
    }

    // MARK: - 8. 1xN / Nx1 edge cases

    func testOneRowFrameResizes() throws {
        let src = try makeFrame(width: 16, height: 1) { x, _ in
            (UInt8(x * 16), 0, 0, 0xFF)
        }
        let out = try FrameResizer.resize(src, toWidth: 8, toHeight: 1, quality: .nearest)
        XCTAssertEqual(out.width, 8)
        XCTAssertEqual(out.height, 1)
    }

    func testOneColumnFrameResizes() throws {
        let src = try makeFrame(width: 1, height: 16) { _, y in
            (0, UInt8(y * 16), 0, 0xFF)
        }
        let out = try FrameResizer.resize(src, toWidth: 1, toHeight: 8, quality: .bilinear)
        XCTAssertEqual(out.width, 1)
        XCTAssertEqual(out.height, 8)
    }

    // MARK: - 9. 1080p-class realistic size (v0.9.1 H.3 standing rule)

    /// Real-frame-size test: 1920×1080 source → 1280×720 target through
    /// every filter. Asserts output dimensions + that the result has
    /// non-zero entropy (i.e. the resize actually wrote pixels — not
    /// an all-zero buffer).
    func test1080pDownscaleAllFilters() throws {
        let src = try makeFrame(width: 1920, height: 1080) { x, y in
            // Diagonal gradient on each channel — every pixel differs.
            (UInt8(x & 0xFF), UInt8(y & 0xFF), UInt8((x + y) & 0xFF), 0xFF)
        }
        for q in ResizeQuality.allCases {
            let out = try FrameResizer.resize(src, toWidth: 1280, toHeight: 720, quality: q)
            XCTAssertEqual(out.width, 1280)
            XCTAssertEqual(out.height, 720)
            // Non-zero entropy: at least two distinct pixel values in
            // the output. (Sampling a few; a degenerate all-zero buffer
            // would fail this.)
            let pA = readPixel(out, x: 100, y: 100)
            let pB = readPixel(out, x: 1100, y: 600)
            // Compare tuples element-wise (Swift's XCTAssertNotEqual
            // doesn't auto-conform tuples to Equatable).
            let differs = (pA.0 != pB.0) || (pA.1 != pB.1)
                       || (pA.2 != pB.2) || (pA.3 != pB.3)
            XCTAssertTrue(differs,
                          "(\(q)) 1080p→720p output should have non-zero entropy — got identical pixels \(pA) at distant positions")
        }
    }
}
