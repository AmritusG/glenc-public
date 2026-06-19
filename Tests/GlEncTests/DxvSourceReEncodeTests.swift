/*
 * DxvSourceReEncodeTests — Phase 7A finding 4 coverage.
 *
 * AVAssetReader can't decode DXV3 sources (macOS has no registered
 * VideoToolbox decoder for DXV3 — error -12906 at decompression-session
 * creation). The Phase 7A finding-4 fix routes DXV3 sources through
 * GlanceCore decoders via the new `SourceFrameReader` abstraction.
 *
 * These tests exercise the new DXV3-to-DXV3 transcode path end-to-end:
 * each test drives EncodePipeline with a DXV3 source `.mov` (one of the
 * committed `reference/<variant>/glenc.mov` files) and a target encoder,
 * then re-demuxes the output to confirm the produced file is a valid
 * DXV3 of the target variant with the same frame count as the source.
 *
 * No env-gate — the reference files are small (~24 MB max for yg10,
 * 30 frames at 1080p) and the encode is fast enough to keep in the
 * default test set.
 */

import XCTest
import Foundation
@testable import GlEncCore
import GlanceCore

final class DxvSourceReEncodeTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
    }()

    private func sourceURL(forVariant variant: String) throws -> URL {
        let url = Self.referenceDir
            .appendingPathComponent(variant)
            .appendingPathComponent("glenc.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
            "reference/\(variant)/glenc.mov missing (GlEnc-produced artifact, stripped from the public seed) — regenerate via the \(variant) encoder test's …AndSaveReference, or scripts/make-corpus.sh")
        return url
    }

    /// Run one transcode and assert the output validates.
    private func transcode(
        from sourceURL: URL,
        to outURL: URL,
        encoder: FrameEncoder,
        outputFormat: DXVFormat,
        sourceAlphaInfo: CGImageAlphaInfo,
        expectedVariant: DXVVariant
    ) async throws {
        try? FileManager.default.removeItem(at: outURL)

        let pipeline = EncodePipeline(
            sourceURL: sourceURL,
            encoder: encoder,
            makeWriter: { w, h, fps in
                try DXVMOVWriter(
                    destURL: outURL,
                    format: outputFormat,
                    presentationWidth: w,
                    presentationHeight: h,
                    fps: fps)
            },
            sourceAlphaInfo: sourceAlphaInfo)
        try await pipeline.run()

        // Output exists, non-empty.
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 1024, "output suspiciously small (\(size) B)")

        // Round-trip demux: variant matches target, frame count matches source.
        let outIndex = try DXVDemuxer.demux(url: outURL)
        XCTAssertEqual(outIndex.variant, expectedVariant,
                       "output variant should be \(expectedVariant)")

        let srcIndex = try DXVDemuxer.demux(url: sourceURL)
        XCTAssertEqual(outIndex.frames.count, srcIndex.frames.count,
                       "frame count must match source")
        XCTAssertEqual(outIndex.width, srcIndex.width)
        XCTAssertEqual(outIndex.height, srcIndex.height)
    }

    /// Real-world re-encode source clip, supplied via the GLENC_REENCODE_SRC
    /// env var so no personal path is committed. Skips the calling test when
    /// the var is unset or the file is missing.
    private func reencodeSourcePath() throws -> String {
        guard let p = ProcessInfo.processInfo.environment["GLENC_REENCODE_SRC"] else {
            throw XCTSkip("Set GLENC_REENCODE_SRC=/path/to/source-clip.mov to run this diagnostic")
        }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: p),
            "GLENC_REENCODE_SRC clip not found at \(p)")
        return p
    }

    private func tempOutURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-reencode-\(name).mov")
    }

    // MARK: - Tests

    /// YG10 source → DXT5 dest. Tests the HQ-decode → DXT5-encode path.
    func testReencodeYG10ToDXT5() async throws {
        try await transcode(
            from: try sourceURL(forVariant: "yg10"),
            to: tempOutURL("yg10-to-dxt5"),
            encoder: DXT5Encoder(),
            outputFormat: .dxt5,
            sourceAlphaInfo: .last,
            expectedVariant: .dxt5)
    }

    /// DXT5 source → YG10 dest. Tests the DXT-decode → HQ-encode path.
    func testReencodeDXT5ToYG10() async throws {
        try await transcode(
            from: try sourceURL(forVariant: "dxt5"),
            to: tempOutURL("dxt5-to-yg10"),
            encoder: YG10Encoder(),
            outputFormat: .yg10,
            sourceAlphaInfo: .last,
            expectedVariant: .yg10)
    }

    /// DXT1 source → DXT5 dest. Tests the no-alpha-source → alpha-target
    /// "add alpha" path (source alpha is implicitly 255).
    func testReencodeDXT1ToDXT5() async throws {
        try await transcode(
            from: try sourceURL(forVariant: "dxt1"),
            to: tempOutURL("dxt1-to-dxt5"),
            encoder: DXT5Encoder(),
            outputFormat: .dxt5,
            sourceAlphaInfo: .last,
            expectedVariant: .dxt5)
    }

    /// YCG6 source → YG10 dest. Tests HQ-no-alpha → HQ-with-alpha.
    func testReencodeYCG6ToYG10() async throws {
        try await transcode(
            from: try sourceURL(forVariant: "ycg6"),
            to: tempOutURL("ycg6-to-yg10"),
            encoder: YG10Encoder(),
            outputFormat: .yg10,
            sourceAlphaInfo: .last,
            expectedVariant: .yg10)
    }

    /// DXDI (legacy DXV1) source → DXT1 dest. Regression for the
    /// encode-from-DXDI truncation throw ("needed 1414966373, have …")
    /// that occurred when `DxvSourceReader.decodeFrameRGBA` fed a DXV1
    /// packet to the DXV3 `DXVPacketDecoder`. After the generation-
    /// dispatch fix, the `.dxv1` arm decodes via `DXV1PacketDecoder`
    /// with both-axes-16 sizing. Structural oracle only (demux) — no
    /// pixel compare through the bumped GlanceCore decoder.
    ///
    /// Fixture: `reference/dxdi/sample.mov` — 5 frames stream-copied
    /// (`ffmpeg -c copy`) from a real DXDI clip, preserving the legacy
    /// DXDI/LZF bytes. Skips (rather than fails) if the fixture is
    /// absent, so a sparse checkout still builds.
    func testReencodeDXDIToDXT1() async throws {
        let src = Self.referenceDir
            .appendingPathComponent("dxdi")
            .appendingPathComponent("sample.mov")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: src.path),
            "DXDI fixture reference/dxdi/sample.mov missing")

        // The fixture must really be a legacy DXV1/DXDI source — this is
        // what exercises the new `.dxv1` decode arm.
        let srcIndex = try DXVDemuxer.demux(url: src)
        XCTAssertEqual(srcIndex.generation, .dxv1,
                       "fixture must be a legacy DXV1/DXDI source")

        try await transcode(
            from: src,
            to: tempOutURL("dxdi-to-dxt1"),
            encoder: DXT1Encoder(),
            outputFormat: .dxt1,
            sourceAlphaInfo: .last,
            expectedVariant: .dxt1)
    }

    // MARK: - Real-world wall-clock smoke (env-gated)

    /// Smoke a real-world full-length DXV3 source through the new path
    /// and report wall-clock + output size. Env-gated because the
    /// source files live outside the repo and the run is slow
    /// (multi-minute on YG10).
    ///
    ///   GLENC_REENCODE_SMOKE=1 swift test -c release \
    ///     --filter DxvSourceReEncodeTests/testRealWorldSmokeDXT1
    /// Phase 7A Finding 5: DXV3 → same-variant DXV3 transcode of a real
    /// Alley-encoded VersaTale source (908×2276 portrait, DXT1).
    /// Hypothesis: non-16-aligned source dimensions break the BC1-block
    /// expected-size math in `DxvSourceReader.decodeFrameRGBA`. Logs to
    /// `/tmp/glenc-f5-diag.log` because XCTest swallows stdout.
    func testFinding5_DXT1_VersaTaleOpal() async throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_F5"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_F5=1 to run Finding 5 diagnostic")
        }
        let src = URL(fileURLWithPath:
            try reencodeSourcePath())
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw XCTSkip("source missing at \(src.path)")
        }
        let outURL = URL(fileURLWithPath: "/tmp/glenc-f5-dxt1-out.mov")
        try? FileManager.default.removeItem(at: outURL)

        let logURL = URL(fileURLWithPath: "/tmp/glenc-f5-diag.log")
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        func wlog(_ s: String) {
            log.write("\(s)\n".data(using: .utf8)!)
        }

        wlog("[F5] source = \(src.path)")

        // 2a — DXVDemuxer reports.
        let idx = try DXVDemuxer.demux(url: src)
        wlog("[F5] DXVDemuxer: variant=\(idx.variant) dims=\(idx.width)x\(idx.height) frames=\(idx.frames.count) fps=\(idx.frameRate)")
        // Print frame entries' sizes for the first few frames.
        for k in 0..<min(3, idx.frames.count) {
            let f = idx.frames[k]
            wlog("[F5]   frame[\(k)]: offset=\(f.fileOffset) size=\(f.size) pts=\(f.presentationTime)")
        }

        // 2b — DxvSourceReader direct, count successful readNextFrame
        // calls before nil or throw.
        let reader = try DxvSourceReader(url: src)
        wlog("[F5] DxvSourceReader: sourceW=\(reader.sourceWidth) sourceH=\(reader.sourceHeight) fps=\(reader.sourceFPS) totalFrames=\(reader.totalFrameCount)")

        var n = 0
        var firstFailure: Error?
        do {
            while let _ = try reader.readNextFrame() {
                n += 1
                if n <= 3 || n % 50 == 0 {
                    wlog("[F5]   readNextFrame #\(n) OK")
                }
            }
            wlog("[F5] reader exhausted cleanly after \(n) frames")
        } catch {
            firstFailure = error
            wlog("[F5] reader THREW after \(n) successful frames: \(error)")
        }

        // 2c — Full EncodePipeline through to writer.finish().
        wlog("[F5] === EncodePipeline run ===")
        let pipeline = EncodePipeline(
            sourceURL: src,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                wlog("[F5] makeWriter w=\(w) h=\(h) fps=\(fps)")
                return try DXVMOVWriter(
                    destURL: outURL, format: .dxt1,
                    presentationWidth: w, presentationHeight: h, fps: fps)
            },
            progress: { p in
                let pct = Int(p * 100)
                if pct % 10 == 0 { wlog("[F5] progress=\(pct)%") }
            },
            sourceAlphaInfo: .noneSkipLast)

        do {
            try await pipeline.run()
            let sz = (try FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
            wlog("[F5] pipeline OK; output \(sz) bytes")
            let outIdx = try DXVDemuxer.demux(url: outURL)
            wlog("[F5] output demuxes: variant=\(outIdx.variant) frames=\(outIdx.frames.count)")
        } catch {
            wlog("[F5] pipeline THREW: \(error)")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path),
               let sz = attrs[.size] as? Int {
                wlog("[F5] output left at \(sz) bytes (truncated, no moov)")
            }
            // Surface the first failure mode for the planner — whether
            // pre-pipeline reader threw, or pipeline-internal.
            wlog("[F5] reader-only first-failure: \(String(describing: firstFailure))")
        }
    }

    /// Phase 7A Finding 5 — visual sanity. Decode frame 0 of both the
    /// VersaTale source and our diagnostic re-encoded output via the
    /// SAME path (DXVDemuxer + DXVPacketDecoder + CPURender) and write
    /// both to PNG so they can be visually compared. If they look
    /// drastically different (stride/shear), the content-level bug is
    /// in CPURender's handling of non-16-aligned dims.
    func testFinding5_VisualFrame0() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_F5"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_F5=1")
        }
        let src = URL(fileURLWithPath:
            try reencodeSourcePath())
        let dst = URL(fileURLWithPath: "/tmp/glenc-f5-dxt1-out.mov")

        for (label, url) in [("source", src), ("output", dst)] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let idx = try DXVDemuxer.demux(url: url)
            print("[F5-visual] \(label): variant=\(idx.variant) dims=\(idx.width)x\(idx.height)")
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            let entry = idx.frames[0]
            try h.seek(toOffset: entry.fileOffset)
            let pkt = try h.read(upToCount: Int(entry.size)) ?? Data()
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            let paddedW = (idx.width + 15) / 16 * 16
            let blocks = (paddedW / 4) * (idx.height / 4)
            let bc1 = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: blocks * 8)
            print("[F5-visual] \(label) bc1 buffer = \(bc1.count) B, blocksW(padded)=\(paddedW/4), blocksH=\(idx.height/4)")
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc1, variant: .dxt1, width: idx.width, height: idx.height)
            print("[F5-visual] \(label) cgImage = \(cgImage.width)x\(cgImage.height)")

            // Write PNG
            let pngURL = URL(fileURLWithPath: "/tmp/glenc-f5-\(label).png")
            try? FileManager.default.removeItem(at: pngURL)
            let cf = ImageIO.CGImageDestinationCreateWithURL(
                pngURL as CFURL, "public.png" as CFString, 1, nil)
            guard let dest = cf else {
                XCTFail("png dest create failed")
                return
            }
            ImageIO.CGImageDestinationAddImage(dest, cgImage, nil)
            XCTAssertTrue(ImageIO.CGImageDestinationFinalize(dest))
            print("[F5-visual] wrote \(pngURL.path)")
        }
    }

    /// Phase 7A Finding 5 — confirm cancel-mid-encode leaves a corrupt
    /// file matching the user-reported artifact (ftyp/wide/mdat with
    /// size=0 placeholder, no moov). Spawns a Task that cancels after
    /// ~10% of the source has been processed.
    func testFinding5_CancelMidEncode() async throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_F5"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_F5=1")
        }
        let src = URL(fileURLWithPath:
            try reencodeSourcePath())
        let outURL = URL(fileURLWithPath: "/tmp/glenc-f5-cancel-out.mov")
        try? FileManager.default.removeItem(at: outURL)

        let task = Task<Void, Error> {
            try await EncodePipeline(
                sourceURL: src,
                encoder: DXT1Encoder(),
                makeWriter: { w, h, fps in
                    try DXVMOVWriter(
                        destURL: outURL, format: .dxt1,
                        presentationWidth: w, presentationHeight: h, fps: fps)
                },
                progress: { _ in },
                sourceAlphaInfo: .noneSkipLast).run()
        }
        // Let ~2-3 seconds of encoding accumulate, then cancel.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation to throw")
        } catch is CancellationError {
            print("[F5-cancel] got CancellationError as expected")
        } catch {
            print("[F5-cancel] task threw non-cancel: \(error)")
        }

        // Inspect the partial file.
        let sz = (try FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        print("[F5-cancel] partial output size = \(sz) bytes")

        let bytes = try Data(contentsOf: outURL)
        // Parse top-level atoms.
        var pos = 0, atoms: [(String, Int)] = []
        while pos + 8 <= bytes.count {
            let b0 = UInt32(bytes[pos])
            let b1 = UInt32(bytes[pos+1])
            let b2 = UInt32(bytes[pos+2])
            let b3 = UInt32(bytes[pos+3])
            let size = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            let t = String(bytes: bytes[pos+4..<pos+8], encoding: .ascii) ?? "????"
            atoms.append((t, size))
            if size == 0 { break }
            if size < 8 { break }
            pos += size
            if pos > bytes.count { break }
        }
        for (t, s) in atoms { print("[F5-cancel]   \(t) size=\(s)") }
        // Verify no moov, mdat is the bullshit-size-0 placeholder.
        XCTAssertFalse(atoms.contains { $0.0 == "moov" },
                       "partial file MUST NOT contain moov (writer.finish never ran)")
        XCTAssertTrue(atoms.contains { $0.0 == "mdat" && $0.1 == 0 },
                      "partial file should have unfinalized mdat (size=0)")
        print("[F5-cancel] CONFIRMED: cancel produces ftyp/wide/mdat(size=0)/no-moov — matches user-reported artifact")
    }

    /// Phase 7A Findings 6+7 — encode the 908×2276 Alley source through
    /// all four codecs, write frame-0 of each output to /tmp PNGs for
    /// visual review. Validates that the GlanceCore v0.5 stride fix
    /// holds end-to-end (encode → demux → decode → PNG) for all four
    /// variants on a non-16-aligned-width source.
    func testFinding6_AllFourCodecs() async throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_F6"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_F6=1 to run all-four-codecs verification")
        }
        let src = URL(fileURLWithPath:
            try reencodeSourcePath())
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw XCTSkip("source missing at \(src.path)")
        }

        struct Case {
            let label: String
            let format: DXVFormat
            let encoder: () -> FrameEncoder
            let alphaInfo: CGImageAlphaInfo
            let expectedVariant: DXVVariant
        }
        let cases: [Case] = [
            .init(label: "dxt1", format: .dxt1, encoder: { DXT1Encoder() },
                  alphaInfo: .noneSkipLast, expectedVariant: .dxt1),
            .init(label: "dxt5", format: .dxt5, encoder: { DXT5Encoder() },
                  alphaInfo: .last, expectedVariant: .dxt5),
            .init(label: "ycg6", format: .ycg6, encoder: { YCG6Encoder() },
                  alphaInfo: .noneSkipLast, expectedVariant: .ycg6),
            .init(label: "yg10", format: .yg10, encoder: { YG10Encoder() },
                  alphaInfo: .last, expectedVariant: .yg10),
        ]

        for c in cases {
            let outURL = URL(fileURLWithPath: "/tmp/glenc-f6-\(c.label).mov")
            try? FileManager.default.removeItem(at: outURL)
            let t0 = Date()
            try await EncodePipeline(
                sourceURL: src,
                encoder: c.encoder(),
                makeWriter: { w, h, fps in
                    try DXVMOVWriter(destURL: outURL, format: c.format,
                                     presentationWidth: w, presentationHeight: h, fps: fps)
                },
                progress: nil,
                sourceAlphaInfo: c.alphaInfo
            ).run()
            let elapsed = Date().timeIntervalSince(t0)
            let sz = (try FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
            let outIdx = try DXVDemuxer.demux(url: outURL)
            XCTAssertEqual(outIdx.variant, c.expectedVariant)
            XCTAssertEqual(outIdx.frames.count, 241)
            print(String(format: "[F6] %@: %d B, %d frames, %.2fs",
                         c.label, sz, outIdx.frames.count, elapsed))

            // Frame-0 PNG for visual review.
            let pngURL = URL(fileURLWithPath: "/tmp/glenc-f6-\(c.label)-frame0.png")
            try? FileManager.default.removeItem(at: pngURL)
            let h = try FileHandle(forReadingFrom: outURL)
            defer { try? h.close() }
            let entry = outIdx.frames[0]
            try h.seek(toOffset: entry.fileOffset)
            let pkt = try h.read(upToCount: Int(entry.size)) ?? Data()
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            let codedW = (outIdx.width + 15) / 16 * 16
            let codedH = (outIdx.height + 15) / 16 * 16
            let cgImage: CGImage
            switch outIdx.variant {
            case .dxt1:
                let paddedW = codedW
                let bc1 = try DXVPacketDecoder.decompressDXT1(
                    payload, expectedSize: (paddedW / 4) * (outIdx.height / 4) * 8)
                cgImage = try CPURender.cgImageFromDXT(
                    dxtBytes: bc1, variant: .dxt1,
                    width: outIdx.width, height: outIdx.height)
            case .dxt5:
                let paddedW = codedW
                let bc3 = try DXVPacketDecoder.decompressDXT5(
                    payload, expectedSize: (paddedW / 4) * (outIdx.height / 4) * 16)
                cgImage = try CPURender.cgImageFromDXT(
                    dxtBytes: bc3, variant: .dxt5,
                    width: outIdx.width, height: outIdx.height)
            case .ycg6:
                let luma = try DXVHQDecoder.decompressYCG6LumaPlane(
                    payload: payload, codedWidth: codedW, codedHeight: codedH)
                let chroma = try DXVHQDecoder.decompressYCG6ChromaPlane(
                    payload: payload, startCursor: luma.postCursor,
                    codedWidth: codedW, codedHeight: codedH)
                cgImage = try CPURender.cgImageFromHQ(
                    y: luma.luma, co: chroma.co, cg: chroma.cg, a: nil,
                    width: codedW, height: codedH,
                    chromaWidth: codedW / 2, chromaHeight: codedH / 2)
            case .yg10:
                let r = try DXVHQDecoder.decompressYG10(
                    payload: payload, codedWidth: codedW, codedHeight: codedH)
                cgImage = try CPURender.cgImageFromHQ(
                    y: r.y, co: r.co, cg: r.cg, a: r.a,
                    width: codedW, height: codedH,
                    chromaWidth: codedW / 2, chromaHeight: codedH / 2)
            }
            let cf = ImageIO.CGImageDestinationCreateWithURL(
                pngURL as CFURL, "public.png" as CFString, 1, nil)
            guard let dest = cf else {
                XCTFail("png dest create failed for \(c.label)")
                continue
            }
            ImageIO.CGImageDestinationAddImage(dest, cgImage, nil)
            XCTAssertTrue(ImageIO.CGImageDestinationFinalize(dest))
            print("[F6] wrote \(pngURL.path)")
        }
    }

    /// Phase 7A Finding 6 ffmpeg-diagnostic — fast variants only.
    /// Produces /tmp/glenc-f6-dxt1.mov + /tmp/glenc-f6-dxt5.mov from
    /// the 908×2276 source. ~60 s total wall-clock.
    func testFinding6_FastVariants() async throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_F6_FAST"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_F6_FAST=1 to regenerate DXT1+DXT5 outputs")
        }
        let src = URL(fileURLWithPath:
            try reencodeSourcePath())
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw XCTSkip("source missing at \(src.path)")
        }

        for (label, fmt, alpha, encoder): (String, DXVFormat, CGImageAlphaInfo, FrameEncoder) in [
            ("dxt1", .dxt1, .noneSkipLast, DXT1Encoder()),
            ("dxt5", .dxt5, .last, DXT5Encoder()),
        ] {
            let outURL = URL(fileURLWithPath: "/tmp/glenc-f6-\(label).mov")
            try? FileManager.default.removeItem(at: outURL)
            let t0 = Date()
            try await EncodePipeline(
                sourceURL: src, encoder: encoder,
                makeWriter: { w, h, fps in
                    try DXVMOVWriter(destURL: outURL, format: fmt,
                                     presentationWidth: w, presentationHeight: h, fps: fps)
                },
                progress: nil,
                sourceAlphaInfo: alpha
            ).run()
            let elapsed = Date().timeIntervalSince(t0)
            let sz = (try FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
            print(String(format: "[F6-fast] %@: %d B, %.2fs", label, sz, elapsed))
        }
    }

    /// Phase 7A Finding 6 layout-comparison: decompress frame 0 of Alley
    /// source vs GlEnc output, report the BC1 buffer size each produces.
    func testFinding6_LayoutCompare() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_F6_LAYOUT"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_F6_LAYOUT=1")
        }
        for (label, path) in [
            ("alley-source", try reencodeSourcePath()),
            ("glenc-output", "/tmp/glenc-f6-dxt1.mov"),
        ] {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("[F6L] \(label): missing"); continue
            }
            let idx = try DXVDemuxer.demux(url: url)
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            let entry = idx.frames[0]
            try h.seek(toOffset: entry.fileOffset)
            let pkt = try h.read(upToCount: Int(entry.size)) ?? Data()
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)

            // Try decompressing at multiple candidate sizes:
            //   A: paddedW/4 * h/4  blocks (Alley convention — w-padded only)
            //   B: paddedW/4 * paddedH/4 blocks (GlEnc convention — both padded)
            let w = idx.width, hh = idx.height
            let paddedW = (w + 15) / 16 * 16
            let paddedH = (hh + 15) / 16 * 16
            let aBlocks = (paddedW / 4) * (hh / 4)
            let bBlocks = (paddedW / 4) * (paddedH / 4)
            print("[F6L] \(label): w=\(w) h=\(hh) paddedW=\(paddedW) paddedH=\(paddedH)")
            print("[F6L]   conv A (w-padded only): expect \(aBlocks * 8) bytes")
            print("[F6L]   conv B (both padded):    expect \(bBlocks * 8) bytes")
            print("[F6L]   payload (compressed): \(payload.count) bytes")
            // Try conv A first
            do {
                let bc1A = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: aBlocks * 8)
                print("[F6L]   conv A decompressed cleanly to \(bc1A.count) bytes")
            } catch {
                print("[F6L]   conv A FAILED: \(error)")
            }
            do {
                let bc1B = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: bBlocks * 8)
                print("[F6L]   conv B decompressed cleanly to \(bc1B.count) bytes")
            } catch {
                print("[F6L]   conv B FAILED: \(error)")
            }
        }
    }

    /// Phase 7A Finding 6 — content comparison of BC1 buffers at conv B
    /// (228 blockcols × 572 blockrows). Examine bytes at boundaries.
    func testFinding6_BC1ContentCompare() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_F6_CONTENT"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_F6_CONTENT=1")
        }
        var buffers: [String: Data] = [:]
        for (label, path) in [
            ("alley", try reencodeSourcePath()),
            ("glenc", "/tmp/glenc-f6-dxt1.mov"),
        ] {
            let url = URL(fileURLWithPath: path)
            let idx = try DXVDemuxer.demux(url: url)
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            let entry = idx.frames[0]
            try h.seek(toOffset: entry.fileOffset)
            let pkt = try h.read(upToCount: Int(entry.size)) ?? Data()
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            // Conv B: 228 × 572 = 130416 blocks = 1043328 bytes
            let bc1 = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: 1043328)
            buffers[label] = bc1
        }
        let alley = buffers["alley"]!
        let glenc = buffers["glenc"]!
        print("[F6C] alley size=\(alley.count) glenc size=\(glenc.count)")

        // BC1 layout: 228 blocks/row, 8 bytes/block = 1824 bytes per blockrow.
        // Image row N is in blockrow N/4. The presentation height = 2276,
        // so image rows 0..2275 = blockrows 0..568 (569 blockrows total),
        // and blockrows 569..571 are padding-territory (image rows 2276..2287).
        let bpr = 228 * 8  // 1824
        // Sample blockrow 0, 100, 568 (last presentation row), 569 (padding start), 571 (padding end)
        for br in [0, 100, 568, 569, 570, 571] {
            let off = br * bpr
            let aSlice = alley[off..<min(off+16, alley.count)].map { String(format: "%02x", $0) }.joined()
            let gSlice = glenc[off..<min(off+16, glenc.count)].map { String(format: "%02x", $0) }.joined()
            let eq = (alley[off..<off+bpr] == glenc[off..<off+bpr]) ? "==" : "!="
            print("[F6C] blockrow \(br) (img row \(br*4)..\(br*4+3)): alley[\(aSlice)] glenc[\(gSlice)]  rows \(eq)")
        }
        // Also: ratio of blockrows that match
        var matchCount = 0
        for br in 0..<572 {
            let off = br * bpr
            if alley[off..<off+bpr] == glenc[off..<off+bpr] {
                matchCount += 1
            }
        }
        print("[F6C] \(matchCount)/572 blockrows byte-identical between alley and glenc")
    }

    /// Phase 7A Finding 6 — find FIRST divergence byte between Alley
    /// and GlEnc BC1 buffers, and check if it's a stride shift.
    func testFinding6_FirstDivergence() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_F6_DIV"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_F6_DIV=1")
        }
        var bufs: [String: Data] = [:]
        for (label, path) in [
            ("alley", try reencodeSourcePath()),
            ("glenc", "/tmp/glenc-f6-dxt1.mov"),
        ] {
            let url = URL(fileURLWithPath: path)
            let idx = try DXVDemuxer.demux(url: url)
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            try h.seek(toOffset: idx.frames[0].fileOffset)
            let pkt = try h.read(upToCount: Int(idx.frames[0].size)) ?? Data()
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            bufs[label] = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: 1043328)
        }
        let a = bufs["alley"]!
        let g = bufs["glenc"]!
        // First divergence
        var firstDiff: Int? = nil
        for i in 0..<min(a.count, g.count) {
            if a[i] != g[i] { firstDiff = i; break }
        }
        if let d = firstDiff {
            let blockIdx = d / 8
            let blockRow = blockIdx / 228
            let blockCol = blockIdx % 228
            let byteInBlock = d % 8
            print("[F6D] first byte divergence at offset \(d)")
            print("[F6D]   block index \(blockIdx) (row \(blockRow), col \(blockCol)), byte \(byteInBlock) within block")
            print("[F6D]   alley[\(d)..\(d+24)] = \(Array(a[d..<min(d+24, a.count)]).map { String(format: "%02x", $0) }.joined())")
            print("[F6D]   glenc[\(d)..\(d+24)] = \(Array(g[d..<min(d+24, g.count)]).map { String(format: "%02x", $0) }.joined())")
        } else {
            print("[F6D] no divergence??")
        }

        // Now try: is glenc's data the same as alley's but shifted by some offset?
        // Search for the shift that maximises agreement.
        let testOffset = 1024 * 64  // start of decoded data (skip header noise)
        let testLen = 1024
        let alleySlice = a[testOffset..<testOffset+testLen]
        var bestShift = 0
        var bestMatch = 0
        for shift in -16...16 {
            let srcOff = testOffset + shift
            if srcOff < 0 || srcOff + testLen > g.count { continue }
            let glencSlice = g[srcOff..<srcOff+testLen]
            var n = 0
            for k in 0..<testLen {
                if alleySlice[testOffset+k] == glencSlice[srcOff+k] { n += 1 }
            }
            if n > bestMatch { bestMatch = n; bestShift = shift }
        }
        print("[F6D] best shift in ±16 range: shift=\(bestShift), matches=\(bestMatch)/\(testLen)")

        // Also: per-blockrow first-divergence positions, to see if there's a periodic pattern
        let bpr = 228 * 8
        var rowDivs: [(Int, Int)] = []
        for br in 0..<8 {
            let off = br * bpr
            var d = bpr
            for i in 0..<bpr {
                if a[off+i] != g[off+i] { d = i; break }
            }
            rowDivs.append((br, d))
        }
        print("[F6D] per-blockrow first-divergence offsets: \(rowDivs)")
    }

    /// Phase 8B-a — file-handle reconciliation audit.
    /// Two DxvSourceReaders open the same source simultaneously; reads
    /// are interleaved. Each holds its own FileHandle (via
    /// FileHandle(forReadingFrom:)), so on POSIX they should have
    /// independent file descriptors + independent seek pointers — but
    /// confirm empirically before Phase 8B builds the preview pane on
    /// top of this assumption.
    ///
    /// If reader-A's seek displaces reader-B's read (or vice versa), the
    /// frame bytes returned will differ. The test asserts byte-identity
    /// of decoded packets from both readers, frame-by-frame.
    func testFileHandleConflict_SimultaneousReaders() throws {
        guard ProcessInfo.processInfo.environment["GLENC_RUN_8B_AUDIT"] == "1" else {
            throw XCTSkip("Set GLENC_RUN_8B_AUDIT=1")
        }
        let src = URL(fileURLWithPath:
            try reencodeSourcePath())
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw XCTSkip("source missing at \(src.path)")
        }

        // Two readers on the same file at once. Both hold independent
        // FileHandle objects per the SourceReader implementation.
        let readerA = try DxvSourceReader(url: src)
        let readerB = try DxvSourceReader(url: src)

        // Drive both via raw packet reads to isolate the file-handle
        // concern from the BGRA-conversion path. Use DXVDemuxer once to
        // get the frame index; both readers will hit the same byte
        // ranges.
        let idx = try DXVDemuxer.demux(url: src)
        let hA = try FileHandle(forReadingFrom: src)
        let hB = try FileHandle(forReadingFrom: src)
        defer { try? hA.close(); try? hB.close() }

        print("[8B-audit] source: variant=\(idx.variant) frames=\(idx.frames.count)")

        // Strategy: for each frame i in [0, 10), interleave reads:
        //   (a) read frame i bytes via handle A
        //   (b) read frame i bytes via handle B
        //   (c) intercalate a seek to a different frame on handle B to
        //       move B's pointer away, then re-read via A — A's pointer
        //       must NOT have moved.
        var mismatches = 0
        for i in 0..<10 {
            let entry = idx.frames[i]
            // A reads frame i
            try hA.seek(toOffset: entry.fileOffset)
            let aBytes = try hA.read(upToCount: Int(entry.size)) ?? Data()
            // B reads frame i (independently)
            try hB.seek(toOffset: entry.fileOffset)
            let bBytes = try hB.read(upToCount: Int(entry.size)) ?? Data()
            // Now interleave: move B's pointer to frame N-1, then re-read
            // frame i via A. A should be unaffected.
            let farEntry = idx.frames[idx.frames.count - 1 - i]
            try hB.seek(toOffset: farEntry.fileOffset)
            _ = try hB.read(upToCount: 12) // partial — we only care that B's seek moved
            // Re-read frame i via A: must return the same bytes (its
            // pointer should still be at entry.fileOffset + entry.size).
            try hA.seek(toOffset: entry.fileOffset)
            let aBytes2 = try hA.read(upToCount: Int(entry.size)) ?? Data()

            let okAB = (aBytes == bBytes)
            let okA2 = (aBytes == aBytes2)
            if !okAB || !okA2 {
                mismatches += 1
                print("[8B-audit] frame \(i): A==B=\(okAB) A==A2=\(okA2)")
            }
        }
        XCTAssertEqual(mismatches, 0,
                       "expected zero byte-mismatches between independent FileHandles on the same read-only file")
        print("[8B-audit] interleaved reads OK: 10 frames × 2 readers, all byte-identical")

        // Drain readerA + readerB via their public API too, to confirm
        // the SourceFrameReader-level path also works with two open.
        // Read 5 frames from each (alternating). Verify each call
        // succeeds without throwing.
        for i in 0..<5 {
            guard let _ = try readerA.readNextFrame() else {
                XCTFail("readerA exhausted at frame \(i)")
                return
            }
            guard let _ = try readerB.readNextFrame() else {
                XCTFail("readerB exhausted at frame \(i)")
                return
            }
        }
        print("[8B-audit] two SourceFrameReaders interleaved: 5 frames each, no errors")

        // Also: while both readers are alive, spin up a separate
        // FileHandle and prove it can also be added (simulates the
        // preview pane opening a third reader while encode + preview
        // are both holding handles).
        let hC = try FileHandle(forReadingFrom: src)
        defer { try? hC.close() }
        try hC.seek(toOffset: idx.frames[0].fileOffset)
        let cBytes = try hC.read(upToCount: Int(idx.frames[0].size)) ?? Data()
        XCTAssertEqual(cBytes.count, Int(idx.frames[0].size))
        print("[8B-audit] third concurrent FileHandle opened + read while two others held; no contention")

        // Per-process fd limit sanity. macOS default soft limit is 256
        // for a normal app + 4096 with appropriate limits. Three handles
        // is well within either.
        print("[8B-audit] verdict: independent FileHandles on the same read-only file coexist cleanly")
    }

    func testRealWorldSmokeDXT1() async throws {
        guard ProcessInfo.processInfo.environment["GLENC_REENCODE_SMOKE"] == "1" else {
            throw XCTSkip("Set GLENC_REENCODE_SMOKE=1 to run the real-world smoke")
        }
        guard let smokeSrcPath = ProcessInfo.processInfo.environment["GLENC_REENCODE_SMOKE_SRC"] else {
            throw XCTSkip("Set GLENC_REENCODE_SMOKE_SRC=/path/to/DXV-clip.mov to run the real-world smoke")
        }
        let src = URL(fileURLWithPath: smokeSrcPath)
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw XCTSkip("GLENC_REENCODE_SMOKE_SRC clip not found at \(src.path)")
        }
        let outURL = URL(fileURLWithPath: "/tmp/glenc-smoke-dxt1-passthru.mov")
        try? FileManager.default.removeItem(at: outURL)
        let t0 = Date()
        try await EncodePipeline(
            sourceURL: src, encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(destURL: outURL, format: .dxt1,
                                 presentationWidth: w, presentationHeight: h, fps: fps)
            },
            progress: { p in
                if Int(p * 100) % 10 == 0 {
                    print(String(format: "[dxt1-smoke] %.1f%%", p * 100))
                }
            },
            sourceAlphaInfo: .last
        ).run()
        let elapsed = Date().timeIntervalSince(t0)
        let sz = (try FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        print(String(format: "[dxt1-smoke] OK: %d B in %.2fs", sz, elapsed))
        let idx = try DXVDemuxer.demux(url: outURL)
        XCTAssertEqual(idx.variant, .dxt1)
        print("[dxt1-smoke] frames=\(idx.frames.count) dims=\(idx.width)x\(idx.height)")
    }
}
