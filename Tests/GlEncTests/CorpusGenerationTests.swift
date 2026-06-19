/*
 * Corpus generation harness — Phase 5C.2.5.
 *
 * Two env-gated tests that produce GlEnc's PNG-direct test corpora:
 *
 *   GLENC_GEN_SYNTHETIC=1 swift test --filter "CorpusGenerationTests/testGenerateSyntheticCorpus"
 *   GLENC_GEN_REALWORLD=1 swift test --filter "CorpusGenerationTests/testGenerateRealworldCorpus"
 *
 * Both skip by default (XCTSkip) so normal runs don't regenerate the
 * committed PNGs.
 *
 * Why PNG-direct: Phase 5B Arena verdict surfaced that the prior
 * real-content corpus chain (Resolume Alley DXV3 export → ffmpeg →
 * ProRes 4444 intermediate → DXT5 encode) had multiple lossy stages
 * masking encoder quality. v0.5.0+ measures SSIM(GlEnc-decoded vs
 * source PNG) where the source PNG is either (a) synthesized via
 * CoreGraphics (deterministic stress patterns) or (b) decoded directly
 * via GlanceCore from the original DXV3 source (real motion content).
 *
 * Synthetic patterns are 1920×1080 RGBA 8-bit. Real-content frames
 * are 3840×2160 RGBA 8-bit (native source resolution).
 *
 * See reference/CORPUS-METHODOLOGY.md for full details.
 */

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
@testable import GlEncCore
import GlanceCore

final class CorpusGenerationTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
    }()

    // MARK: - Synthetic stress corpus

    func testGenerateSyntheticCorpus() throws {
        guard ProcessInfo.processInfo.environment["GLENC_GEN_SYNTHETIC"] == "1" else {
            throw XCTSkip("Set GLENC_GEN_SYNTHETIC=1 to regenerate reference/synthetic-corpus/")
        }
        let outDir = Self.referenceDir
            .appendingPathComponent("synthetic-corpus/source")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let w = 1920
        let h = 1080

        try writePNG(outDir.appendingPathComponent("01-primaries-opaque.png"),
                     width: w, height: h, draw: { ctx in
            drawVerticalStripes(ctx: ctx, width: w, height: h,
                                colors: primaries(alpha: 255))
        })

        try writePNG(outDir.appendingPathComponent("02-primaries-halfalpha.png"),
                     width: w, height: h, draw: { ctx in
            drawVerticalStripes(ctx: ctx, width: w, height: h,
                                colors: primaries(alpha: 128))
        })

        try writePNG(outDir.appendingPathComponent("03-near-primaries.png"),
                     width: w, height: h, draw: { ctx in
            // 5-LSB inset version of pure primaries.
            let near: [(UInt8, UInt8, UInt8, UInt8)] = [
                (250,   5,   5, 255),
                (  5, 250,   5, 255),
                (  5,   5, 250, 255),
                (250, 250,   5, 255),
                (250,   5, 250, 255),
                (  5, 250, 250, 255),
            ]
            drawVerticalStripes(ctx: ctx, width: w, height: h, colors: near)
        })

        try writePNG(outDir.appendingPathComponent("04-grayscale-ramp.png"),
                     width: w, height: h, draw: { ctx in
            // Horizontal grayscale gradient from 0..255. Step every w/256 px.
            for x in 0..<w {
                let g = UInt8((x * 255) / max(1, w - 1))
                ctx.setFillColor(red: CGFloat(g)/255, green: CGFloat(g)/255,
                                 blue: CGFloat(g)/255, alpha: 1)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
            }
        })

        try writePNG(outDir.appendingPathComponent("05-saturated-gradient-red-green.png"),
                     width: w, height: h, draw: { ctx in
            // (255, 0, 0) → (0, 255, 0) horizontally.
            for x in 0..<w {
                let t = CGFloat(x) / CGFloat(max(1, w - 1))
                ctx.setFillColor(red: 1 - t, green: t, blue: 0, alpha: 1)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
            }
        })

        try writePNG(outDir.appendingPathComponent("06-saturated-gradient-blue-yellow.png"),
                     width: w, height: h, draw: { ctx in
            // (0, 0, 255) → (255, 255, 0) horizontally.
            for x in 0..<w {
                let t = CGFloat(x) / CGFloat(max(1, w - 1))
                ctx.setFillColor(red: t, green: t, blue: 1 - t, alpha: 1)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
            }
        })

        try writePNG(outDir.appendingPathComponent("07-sharp-color-edges.png"),
                     width: w, height: h, draw: { ctx in
            let halfW = w / 2
            let halfH = h / 2
            // top-left cyan, top-right magenta, bottom-left yellow, bottom-right white
            // CG y-axis is bottom-up — adjust accordingly.
            ctx.setFillColor(red: 0, green: 1, blue: 1, alpha: 1)  // cyan
            ctx.fill(CGRect(x: 0, y: halfH, width: halfW, height: halfH))
            ctx.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)  // magenta
            ctx.fill(CGRect(x: halfW, y: halfH, width: halfW, height: halfH))
            ctx.setFillColor(red: 1, green: 1, blue: 0, alpha: 1)  // yellow
            ctx.fill(CGRect(x: 0, y: 0, width: halfW, height: halfH))
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)  // white
            ctx.fill(CGRect(x: halfW, y: 0, width: halfW, height: halfH))
        })

        try writePNG(outDir.appendingPathComponent("08-alpha-hard-edge.png"),
                     width: w, height: h, draw: { ctx in
            // Full red across the whole frame.
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Right half: stomp alpha to 0 by clearing that region.
            // CGContext doesn't allow direct alpha-channel writes; instead
            // use .copy blend mode with a transparent fill on the right half.
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0)
            ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
            ctx.restoreGState()
        })

        try writePNG(outDir.appendingPathComponent("09-alpha-smooth-gradient.png"),
                     width: w, height: h, draw: { ctx in
            // Green underneath, alpha ramps 0..255 left-to-right.
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            for x in 0..<w {
                let a = CGFloat(x) / CGFloat(max(1, w - 1))
                ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: a)
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
            }
            ctx.restoreGState()
        })

        try writePNG(outDir.appendingPathComponent("10-text-on-transparent.png"),
                     width: w, height: h, draw: { ctx in
            // Anti-aliased magenta text on transparent. Non-white text
            // colour so spot-checking the PNG in Preview (which renders
            // transparency as white) shows the text glyphs cleanly.
            // For encoder testing, what matters is the anti-aliased α
            // edge on the glyph boundaries — colour choice is irrelevant.
            let fontSize: CGFloat = 200
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let attr: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: CGColor(red: 1, green: 0, blue: 1, alpha: 1)
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: "GlEnc 0.5.0", attributes: attr))
            let bounds = CTLineGetBoundsWithOptions(line, [])
            let x = (CGFloat(w) - bounds.width) / 2
            let y = (CGFloat(h) - bounds.height) / 2
            ctx.textPosition = CGPoint(x: x, y: y)
            ctx.setShouldAntialias(true)
            CTLineDraw(line, ctx)
        })

        try writePNG(outDir.appendingPathComponent("11-gradient-with-chromakey-hole.png"),
                     width: w, height: h, draw: { ctx in
            // Diagonal gradient background (red→blue).
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                    CGColor(red: 0, green: 0, blue: 1, alpha: 1)
                ] as CFArray,
                locations: [0, 1])!
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: CGFloat(w), y: CGFloat(h)),
                options: [])
            // Circular hole of α=0 in the middle.
            let radius = CGFloat(min(w, h)) / 4
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0)
            ctx.fillEllipse(in: CGRect(
                x: CGFloat(w) / 2 - radius,
                y: CGFloat(h) / 2 - radius,
                width: radius * 2, height: radius * 2))
            ctx.restoreGState()
        })

        try writePNG(outDir.appendingPathComponent("12-mixed-alpha-saturation.png"),
                     width: w, height: h, draw: { ctx in
            // 5 horizontal rows × 6 primary cols. Each row has a fixed α value.
            // Top-most row α=0 (invisible-but-RGB-still-present), then 64, 128, 192, 255.
            // CG y-axis is bottom-up.
            let alphaLevels: [CGFloat] = [0, 64, 128, 192, 255].map { $0 / 255 }
            let cols = primaries(alpha: 255)
            let rowH = h / alphaLevels.count
            let colW = w / cols.count
            for (rowIdx, a) in alphaLevels.enumerated() {
                let y = rowIdx * rowH
                for (colIdx, c) in cols.enumerated() {
                    let x = colIdx * colW
                    ctx.saveGState()
                    ctx.setBlendMode(.copy)
                    ctx.setFillColor(
                        red: CGFloat(c.0) / 255,
                        green: CGFloat(c.1) / 255,
                        blue: CGFloat(c.2) / 255,
                        alpha: a)
                    ctx.fill(CGRect(x: x, y: y, width: colW, height: rowH))
                    ctx.restoreGState()
                }
            }
        })

        // List what we wrote.
        let pngs = try FileManager.default.contentsOfDirectory(at: outDir,
                                                               includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var totalBytes = 0
        print("[synthetic-corpus] wrote \(pngs.count) PNGs:")
        for p in pngs {
            let sz = (try p.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalBytes += sz
            print(String(format: "  %@: %.1f KB", p.lastPathComponent, Double(sz) / 1024))
        }
        print(String(format: "[synthetic-corpus] total: %.1f KB", Double(totalBytes) / 1024))
    }

    // MARK: - Real-content corpus via GlanceCore

    /// Decode 30 frames from ShroomiesKingdom_29.mov (densest packet-size
    /// window, frames 199-228) directly through GlanceCore.DXVDemuxer +
    /// DXVPacketDecoder + CPURender, save as PNG sequence to
    /// reference/realworld-corpus/source/.
    ///
    /// Source variant note: ShroomiesKingdom_29.mov is DXT1-encoded
    /// (no alpha), not DXT5. Per-frame tag is `31 54 58 44` ("DXT1" LE).
    /// FFprobe reports `pix_fmt=rgba` but that's FFmpeg's DXV decoder
    /// always declaring rgba output; for DXT1 the alpha channel is 255.
    /// The real-content corpus validates color/saturation/motion fidelity
    /// on DXT1; alpha-bearing real content needs a separate DXT5 / YG10
    /// source clip (synthetic corpus covers alpha exhaustively
    /// in the meantime).
    func testGenerateRealworldCorpus() throws {
        guard ProcessInfo.processInfo.environment["GLENC_GEN_REALWORLD"] == "1" else {
            throw XCTSkip("Set GLENC_GEN_REALWORLD=1 to regenerate reference/realworld-corpus/")
        }
        // Source clip is local-only media supplied via GLENC_REALWORLD_SRC
        // (e.g. by `scripts/make-corpus.sh [path]`) so no personal path is
        // committed. Skips when unset.
        guard let sourcePath = ProcessInfo.processInfo.environment["GLENC_REALWORLD_SRC"] else {
            throw XCTSkip("Set GLENC_REALWORLD_SRC=/path/to/clip.mov to regenerate the real-world corpus (or pass it to scripts/make-corpus.sh)")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("real-world source clip not found at \(sourceURL.path)")
        }
        let outDir = Self.referenceDir
            .appendingPathComponent("realworld-corpus/source")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // Clear any previous run.
        for u in try FileManager.default.contentsOfDirectory(at: outDir,
                                                             includingPropertiesForKeys: nil)
            where u.pathExtension == "png" {
            try FileManager.default.removeItem(at: u)
        }

        // (1) Demux the file.
        let index = try DXVDemuxer.demux(url: sourceURL)
        let w = index.width
        let h = index.height
        let variant = index.variant
        print("[realworld] source: \(w)×\(h), \(index.frames.count) frames, variant=\(variant.displayName)")
        XCTAssertEqual(variant, .dxt1,
                       "ShroomiesKingdom_29.mov is DXT1; if this asserts, the source clip changed and the decode path below needs updating")

        // (2) Open the file for seeking.
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        // (3) Decode the densest 30-frame window.
        //
        // Chosen via `ffprobe -show_entries packet=size -select_streams v
        // -of csv=p=0 …` + a sliding-window awk: frames 199..228 carry the
        // largest summed DXV3 payload (91.2 MB) over any 30-frame interval
        // of the 900-frame clip. Picks dense motion content, skips any
        // intro/outro fades.
        let firstFrame = 199
        let frameCount = 30
        let paddedW = (w + 15) / 16 * 16   // BC1 padding for decode
        let blocksW = paddedW / 4
        let blocksH = h / 4
        let blocks = blocksW * blocksH

        let t0 = Date()
        for i in 0..<frameCount {
            let absIdx = firstFrame + i
            guard absIdx < index.frames.count else {
                XCTFail("window extends past clip: \(absIdx) >= \(index.frames.count)")
                return
            }
            let entry = index.frames[absIdx]
            try handle.seek(toOffset: entry.fileOffset)
            let pktBytes = try handle.read(upToCount: Int(entry.size)) ?? Data()
            XCTAssertEqual(pktBytes.count, Int(entry.size),
                           "frame \(absIdx) packet read short")

            let (_, payload) = try DXVPacketDecoder.parseHeader(pktBytes)
            let bc1 = try DXVPacketDecoder.decompressDXT1(
                payload, expectedSize: blocks * 8)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc1, variant: .dxt1, width: w, height: h)

            let frameURL = outDir.appendingPathComponent(
                String(format: "frame_%04d.png", i + 1))
            try writePNG(frameURL, image: cgImage)
        }
        let elapsed = Date().timeIntervalSince(t0)
        print(String(format: "[realworld] decoded %d frames in %.2fs", frameCount, elapsed))

        let pngs = try FileManager.default.contentsOfDirectory(
            at: outDir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var totalBytes = 0
        for p in pngs {
            let sz = (try p.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalBytes += sz
        }
        print(String(format: "[realworld] wrote %d PNGs, total %.1f MB",
                     pngs.count, Double(totalBytes) / 1_048_576))
    }

    // MARK: - Phase 5C.3.5 paired real-content HQ/Normal corpora

    /// Decode 30 frames from `ShroomiesKingdom_05_DXV High Quality With Alpha.mov`
    /// (YG10, 3840×2160, 300 frames, 10 s) through GlanceCore's HQ path
    /// and save to reference/realworld-yg10-corpus/source/.
    ///
    /// Densest 30-frame window: frames 65..94 (2.17 s..3.13 s of the
    /// clip), 48.4 MB summed YG10 payload — selected via ffprobe
    /// packet-size sliding window. The DXT5 paired corpus uses the
    /// same frame range so the two are frame-aligned by source content.
    func testGenerateYG10RealworldCorpus() throws {
        guard ProcessInfo.processInfo.environment["GLENC_GEN_YG10_REALWORLD"] == "1" else {
            throw XCTSkip("Set GLENC_GEN_YG10_REALWORLD=1 to regenerate reference/realworld-yg10-corpus/")
        }
        guard let sourcePath = ProcessInfo.processInfo.environment["GLENC_YG10_REALWORLD_SRC"] else {
            throw XCTSkip("Set GLENC_YG10_REALWORLD_SRC=/path/to/yg10-clip.mov to regenerate the YG10 paired corpus")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("GLENC_YG10_REALWORLD_SRC clip not found at \(sourceURL.path)")
        }
        let outDir = Self.referenceDir
            .appendingPathComponent("realworld-yg10-corpus/source")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for u in try FileManager.default.contentsOfDirectory(
            at: outDir, includingPropertiesForKeys: nil
        ) where u.pathExtension == "png" {
            try FileManager.default.removeItem(at: u)
        }

        let index = try DXVDemuxer.demux(url: sourceURL)
        let w = index.width
        let h = index.height
        print("[yg10-corpus] source: \(w)×\(h), \(index.frames.count) frames, variant=\(index.variant.displayName)")
        XCTAssertEqual(index.variant, .yg10,
                       "expected YG10 variant; if this asserts, the source clip changed")

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        // HQ decode requires 16-aligned coded dims. 3840 and 2160 are
        // both 16-aligned for this 4K source.
        let codedW = (w + 15) / 16 * 16
        let codedH = (h + 15) / 16 * 16
        let chromaW = codedW / 2
        let chromaH = codedH / 2
        XCTAssertEqual(codedW, w, "expected w to be 16-aligned (3840)")
        XCTAssertEqual(codedH, h, "expected h to be 16-aligned (2160)")

        // Densest 30-frame window: frames 65..94.
        let firstFrame = 65
        let frameCount = 30

        let t0 = Date()
        for i in 0..<frameCount {
            let absIdx = firstFrame + i
            guard absIdx < index.frames.count else {
                XCTFail("window extends past clip: \(absIdx) >= \(index.frames.count)")
                return
            }
            let entry = index.frames[absIdx]
            try handle.seek(toOffset: entry.fileOffset)
            let pktBytes = try handle.read(upToCount: Int(entry.size)) ?? Data()
            XCTAssertEqual(pktBytes.count, Int(entry.size))

            let (_, payload) = try DXVPacketDecoder.parseHeader(pktBytes)
            let result = try DXVHQDecoder.decompressYG10(
                payload: payload, codedWidth: codedW, codedHeight: codedH)
            // codedW/codedH == w/h for this 4K source (3840 × 2160, both
            // 16-aligned). cgImageFromHQ's pinned GlanceCore@0.4.13
            // signature doesn't include `displayWidth`; no crop needed.
            let cgImage = try CPURender.cgImageFromHQ(
                y: result.y, co: result.co, cg: result.cg, a: result.a,
                width: codedW, height: codedH,
                chromaWidth: chromaW, chromaHeight: chromaH)

            let frameURL = outDir.appendingPathComponent(
                String(format: "frame_%04d.png", i + 1))
            try writePNG(frameURL, image: cgImage)
        }
        let elapsed = Date().timeIntervalSince(t0)
        print(String(format: "[yg10-corpus] decoded %d frames in %.2fs", frameCount, elapsed))

        let pngs = try FileManager.default.contentsOfDirectory(
            at: outDir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "png" }
        var totalBytes = 0
        for p in pngs {
            totalBytes += (try p.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        print(String(format: "[yg10-corpus] wrote %d PNGs, total %.1f MB",
                     pngs.count, Double(totalBytes) / 1_048_576))
    }

    /// Decode the same frame window from the paired DXT5 file —
    /// `ShroomiesKingdom_05_DXV Normal Quality With Alpha.mov` — through
    /// GlanceCore's DXT5 path. Frame-aligned with the YG10 corpus by
    /// source content, so `realworld-yg10-corpus/source/frame_NNNN.png`
    /// and `realworld-dxt5-paired-corpus/source/frame_NNNN.png`
    /// represent the same source frame decoded through different DXV3
    /// variants. Visual comparison shows the real-content quality
    /// tradeoff between Normal and HQ encoder pipelines.
    func testGenerateDXT5PairedRealworldCorpus() throws {
        guard ProcessInfo.processInfo.environment["GLENC_GEN_DXT5_PAIRED"] == "1" else {
            throw XCTSkip("Set GLENC_GEN_DXT5_PAIRED=1 to regenerate reference/realworld-dxt5-paired-corpus/")
        }
        guard let sourcePath = ProcessInfo.processInfo.environment["GLENC_DXT5_PAIRED_SRC"] else {
            throw XCTSkip("Set GLENC_DXT5_PAIRED_SRC=/path/to/dxt5-clip.mov to regenerate the DXT5 paired corpus")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("GLENC_DXT5_PAIRED_SRC clip not found at \(sourceURL.path)")
        }
        let outDir = Self.referenceDir
            .appendingPathComponent("realworld-dxt5-paired-corpus/source")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for u in try FileManager.default.contentsOfDirectory(
            at: outDir, includingPropertiesForKeys: nil
        ) where u.pathExtension == "png" {
            try FileManager.default.removeItem(at: u)
        }

        let index = try DXVDemuxer.demux(url: sourceURL)
        let w = index.width
        let h = index.height
        print("[dxt5-paired] source: \(w)×\(h), \(index.frames.count) frames, variant=\(index.variant.displayName)")
        XCTAssertEqual(index.variant, .dxt5,
                       "expected DXT5 variant; if this asserts, the source clip changed")

        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }

        let paddedW = (w + 15) / 16 * 16
        let blocksW = paddedW / 4
        let blocksH = h / 4
        let blocks = blocksW * blocksH

        // Same frame range as the YG10 corpus — frames 65..94.
        let firstFrame = 65
        let frameCount = 30

        let t0 = Date()
        for i in 0..<frameCount {
            let absIdx = firstFrame + i
            guard absIdx < index.frames.count else {
                XCTFail("window extends past clip: \(absIdx) >= \(index.frames.count)")
                return
            }
            let entry = index.frames[absIdx]
            try handle.seek(toOffset: entry.fileOffset)
            let pktBytes = try handle.read(upToCount: Int(entry.size)) ?? Data()
            XCTAssertEqual(pktBytes.count, Int(entry.size))

            let (_, payload) = try DXVPacketDecoder.parseHeader(pktBytes)
            let bc3 = try DXVPacketDecoder.decompressDXT5(
                payload, expectedSize: blocks * 16)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc3, variant: .dxt5, width: w, height: h)

            let frameURL = outDir.appendingPathComponent(
                String(format: "frame_%04d.png", i + 1))
            try writePNG(frameURL, image: cgImage)
        }
        let elapsed = Date().timeIntervalSince(t0)
        print(String(format: "[dxt5-paired] decoded %d frames in %.2fs", frameCount, elapsed))

        let pngs = try FileManager.default.contentsOfDirectory(
            at: outDir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "png" }
        var totalBytes = 0
        for p in pngs {
            totalBytes += (try p.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        print(String(format: "[dxt5-paired] wrote %d PNGs, total %.1f MB",
                     pngs.count, Double(totalBytes) / 1_048_576))
    }

    // MARK: - Helpers

    private func primaries(alpha: UInt8) -> [(UInt8, UInt8, UInt8, UInt8)] {
        return [
            (255,   0,   0, alpha),  // red
            (  0, 255,   0, alpha),  // green
            (  0,   0, 255, alpha),  // blue
            (255, 255,   0, alpha),  // yellow
            (255,   0, 255, alpha),  // magenta
            (  0, 255, 255, alpha),  // cyan
        ]
    }

    private func drawVerticalStripes(
        ctx: CGContext, width: Int, height: Int,
        colors: [(UInt8, UInt8, UInt8, UInt8)]
    ) {
        let stripeW = width / colors.count
        for (i, c) in colors.enumerated() {
            let x = i * stripeW
            let cgWidth = (i == colors.count - 1) ? width - x : stripeW
            ctx.saveGState()
            ctx.setBlendMode(.copy)
            ctx.setFillColor(
                red: CGFloat(c.0) / 255,
                green: CGFloat(c.1) / 255,
                blue: CGFloat(c.2) / 255,
                alpha: CGFloat(c.3) / 255)
            ctx.fill(CGRect(x: x, y: 0, width: cgWidth, height: height))
            ctx.restoreGState()
        }
    }

    /// Create a CGContext at the requested dimensions, run `draw`, and
    /// write PNG via ImageIO.
    private func writePNG(
        _ url: URL, width: Int, height: Int,
        draw: (CGContext) -> Void
    ) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bmpInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: bmpInfo
        ) else {
            throw NSError(domain: "CorpusGen", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "CGContext create failed"])
        }
        // Zero-fill (CGContext init doesn't guarantee zeroing).
        ctx.setBlendMode(.copy)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Reset blend for normal drawing.
        ctx.setBlendMode(.normal)

        draw(ctx)

        guard let cgImage = ctx.makeImage() else {
            throw NSError(domain: "CorpusGen", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "makeImage failed"])
        }
        try writePNG(url, image: cgImage)
    }

    private func writePNG(_ url: URL, image: CGImage) throws {
        let utType = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, utType, 1, nil
        ) else {
            throw NSError(domain: "CorpusGen", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "PNG destination create failed: \(url.path)"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "CorpusGen", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "PNG write failed: \(url.path)"])
        }
    }
}
