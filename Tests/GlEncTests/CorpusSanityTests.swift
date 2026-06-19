/*
 * Corpus sanity test — Phase 5C.2.5.
 *
 * "Are the PNG corpora loadable and well-formed?" Verifies the
 * methodology rebuild's outputs (reference/synthetic-corpus/ and
 * reference/realworld-corpus/) are usable by the test harness without
 * actually running any encoder paths. Encoder-quality measurement
 * happens in Phase 5C.2.7 onward — this is just structural validation.
 *
 * Skipped automatically if the corpora aren't present (e.g. fresh
 * checkout without LFS smudge): we don't want this to be a fail-fast
 * blocker on environments missing the LFS objects.
 */

import XCTest
import CoreGraphics
import ImageIO
import Foundation
@testable import GlEncCore

final class CorpusSanityTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
    }()

    // MARK: - Synthetic corpus

    /// Verifies the 12 synthetic stress patterns exist, load via
    /// `CGImageSource`, and report the expected 1920×1080 RGBA layout.
    func testSyntheticCorpusLoadable() throws {
        let dir = Self.referenceDir.appendingPathComponent("synthetic-corpus/source")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("synthetic-corpus missing — run GLENC_GEN_SYNTHETIC=1 ... testGenerateSyntheticCorpus to regenerate")
        }
        let expected: [String] = [
            "01-primaries-opaque.png",
            "02-primaries-halfalpha.png",
            "03-near-primaries.png",
            "04-grayscale-ramp.png",
            "05-saturated-gradient-red-green.png",
            "06-saturated-gradient-blue-yellow.png",
            "07-sharp-color-edges.png",
            "08-alpha-hard-edge.png",
            "09-alpha-smooth-gradient.png",
            "10-text-on-transparent.png",
            "11-gradient-with-chromakey-hole.png",
            "12-mixed-alpha-saturation.png",
        ]
        for name in expected {
            let url = dir.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "synthetic corpus missing PNG: \(name)")
            let (w, h, hasAlpha) = try probePNG(url)
            XCTAssertEqual(w, 1920, "\(name) width should be 1920")
            XCTAssertEqual(h, 1080, "\(name) height should be 1080")
            XCTAssertTrue(hasAlpha, "\(name) should carry an alpha channel")
        }
    }

    // MARK: - Real-content corpus

    /// Verifies the 30 ShroomiesKingdom_29 frames exist, load, and report
    /// 3840×2160 RGBA. Skipped if the corpus isn't present.
    func testRealworldCorpusLoadable() throws {
        let dir = Self.referenceDir.appendingPathComponent("realworld-corpus/source")
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw XCTSkip("realworld-corpus missing — run GLENC_GEN_REALWORLD=1 ... testGenerateRealworldCorpus to regenerate")
        }
        for i in 1...30 {
            let url = dir.appendingPathComponent(String(format: "frame_%04d.png", i))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "realworld corpus missing frame \(i)")
            let (w, h, hasAlpha) = try probePNG(url)
            XCTAssertEqual(w, 3840, "frame \(i) width should be 3840")
            XCTAssertEqual(h, 2160, "frame \(i) height should be 2160")
            XCTAssertTrue(hasAlpha, "frame \(i) should carry an alpha channel (PNG decode preserves it even if source variant is DXT1)")
        }
    }

    /// Spot-check that loading a synthetic primaries PNG produces the
    /// exact RGB bytes we wrote (alpha may be premultiplied by
    /// `CGImageSource` — that's a load-path detail; what matters is
    /// the encoder gets the same bytes the writer produced). Catches
    /// CG colorspace or premultiplication surprises early.
    func testSyntheticCorpusRGBAPixelSurprises() throws {
        let url = Self.referenceDir
            .appendingPathComponent("synthetic-corpus/source/01-primaries-opaque.png")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("synthetic-corpus missing")
        }
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
            XCTFail("cannot decode primaries-opaque.png")
            return
        }
        // Render into a packed RGBA buffer for byte sampling.
        let w = cgImage.width
        let h = cgImage.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        try rgba.withUnsafeMutableBufferPointer { buf in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let bmpInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: bmpInfo
            ) else {
                throw NSError(domain: "CSanity", code: 1)
            }
            ctx.setBlendMode(.copy)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Centre of stripe 0 (red) and stripe 1 (green). Tolerate ±2 LSB.
        let stripeW = w / 6
        let cx0 = stripeW / 2
        let cx1 = stripeW + stripeW / 2
        let cy = h / 2
        let off0 = (cy * w + cx0) * 4
        let off1 = (cy * w + cx1) * 4
        XCTAssertLessThanOrEqual(abs(Int(rgba[off0    ]) - 255), 2, "red stripe R")
        XCTAssertLessThanOrEqual(abs(Int(rgba[off0 + 1]) -   0), 2, "red stripe G")
        XCTAssertLessThanOrEqual(abs(Int(rgba[off0 + 2]) -   0), 2, "red stripe B")
        XCTAssertEqual(rgba[off0 + 3], 255, "red stripe alpha")
        XCTAssertLessThanOrEqual(abs(Int(rgba[off1    ]) -   0), 2, "green stripe R")
        XCTAssertLessThanOrEqual(abs(Int(rgba[off1 + 1]) - 255), 2, "green stripe G")
        XCTAssertLessThanOrEqual(abs(Int(rgba[off1 + 2]) -   0), 2, "green stripe B")
        XCTAssertEqual(rgba[off1 + 3], 255, "green stripe alpha")
    }

    // MARK: - Helpers

    /// Probe a PNG via `CGImageSource` properties — width, height,
    /// alpha presence. Doesn't decode pixel data.
    private func probePNG(_ url: URL) throws -> (Int, Int, Bool) {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(domain: "CSanity", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "CGImageSourceCreateWithURL failed: \(url.lastPathComponent)"])
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(imgSrc, 0, nil)
                as? [CFString: Any] else {
            throw NSError(domain: "CSanity", code: 11)
        }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
        return (w, h, hasAlpha)
    }
}
