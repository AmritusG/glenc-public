/*
 * Multi-Format Phase 2a — H.264 / HEVC (opaque) through the
 * AVAssetWriterVideoSink, both .mov and .mp4 containers, plus a
 * rate-control-applies proof. VideoToolbox output is non-deterministic
 * → round-trip/structural + size-delta assertions, never byte-pinned.
 */
import XCTest
import AVFoundation
import CoreVideo
import Darwin
@testable import GlEncCore

final class VideoCodecSinkTests: XCTestCase {

    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    private func fixture(_ rel: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(rel)
    }
    private func tmpOut(_ name: String, _ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-vt-\(name)-\(UUID().uuidString).\(ext)")
    }

    private func codecTag(_ url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let fmt = try await track.load(.formatDescriptions).first else { return "----" }
        let st = CMFormatDescriptionGetMediaSubType(fmt)
        let bytes = [UInt8((st >> 24) & 0xff), UInt8((st >> 16) & 0xff),
                     UInt8((st >> 8) & 0xff), UInt8(st & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "----"
    }
    private func dimsAndCount(_ url: URL) async throws -> (Int, Int, Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return (0,0,0) }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out); reader.startReading()
        var w = 0, h = 0, n = 0
        while let sb = out.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                w = CVPixelBufferGetWidth(pb); h = CVPixelBufferGetHeight(pb)
            }
            n += 1
        }
        return (w, h, n)
    }

    private func encode(_ src: URL, codec: AVVideoCodecType, container: OutputContainer,
                        out: URL, props: [String: Any] = [:]) async throws {
        try await EncodePipeline(
            sourceURL: src,
            makeSink: { w, h, _ in
                try AVAssetWriterVideoSink(
                    destURL: out, codec: codec, fileType: container.fileType,
                    width: w, height: h, compressionProperties: props)
            }).run()
    }

    // MARK: - both codecs, both containers, decode correctly

    func testH264AndHEVC_BothContainers_DecodeCorrectly() async throws {
        let src = fixture("reference/fps/ntsc2997_h264.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "fixture missing: \(src.path)")
        let (_, _, srcCount) = try await dimsAndCount(src)
        XCTAssertGreaterThan(srcCount, 0)

        let cases: [(String, AVVideoCodecType, Set<String>)] = [
            ("h264", .h264, ["avc1"]),
            ("hevc", .hevc, ["hvc1", "hev1"]),
        ]
        for (name, codec, okTags) in cases {
            for container in [OutputContainer.mov, .mp4] {
                let out = tmpOut("\(name)-\(container.ext)", container.ext)
                defer { try? FileManager.default.removeItem(at: out) }
                try await encode(src, codec: codec, container: container, out: out)

                XCTAssertTrue(FileManager.default.fileExists(atPath: out.path),
                              "\(name)/\(container.ext): no output")
                let tag = try await codecTag(out)
                XCTAssertTrue(okTags.contains(tag),
                              "\(name)/\(container.ext): tag \(tag) not in \(okTags)")
                let (w, h, n) = try await dimsAndCount(out)
                XCTAssertGreaterThan(w, 0); XCTAssertGreaterThan(h, 0)
                XCTAssertEqual(n, srcCount,
                               "\(name)/\(container.ext): frame count \(n) != \(srcCount)")
            }
        }
    }

    // MARK: - rate-control actually applies (bitrate → size delta)

    func testBitrateKnobAffectsOutputSize() async throws {
        let src = fixture("reference/fps/clean30_h264.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "fixture missing: \(src.path)")

        func sizeAt(_ mbps: Double) async throws -> Int {
            let out = tmpOut("br\(Int(mbps))", "mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            let props = VideoEncodeSettings(rateControl: .bitrate(mbps))
                .compressionProperties(includeH264Profile: true)
            try await encode(src, codec: .h264, container: .mp4, out: out, props: props)
            let attrs = try FileManager.default.attributesOfItem(atPath: out.path)
            return (attrs[.size] as? Int) ?? 0
        }

        let low = try await sizeAt(1)     // 1 Mbps
        let high = try await sizeAt(20)   // 20 Mbps
        print("[vt-bitrate] 1Mbps=\(low)B  20Mbps=\(high)B  ratio=\(Double(high)/Double(max(1,low)))")
        XCTAssertGreaterThan(low, 0)
        XCTAssertGreaterThan(high, low * 2,
            "20 Mbps output (\(high)B) must be materially larger than 1 Mbps (\(low)B) — knob is live")
    }

    // MARK: - Odd / even-non-4 dimensions (codec-aware alignment)

    func testOddAndEvenDims_ProResMJPEGExact_H264HEVCEven() async throws {
        let src = fixture("reference/fps/ntsc2997_h264.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "fixture missing")
        // A real source is needed only for frame timing; we feed the sink a
        // synthetic odd/even-non-4 frame directly via a 1-frame pipeline is
        // overkill — instead drive the sink with a resize through the
        // pipeline is also overkill. Use the sink directly with a synthetic
        // buffer to test exact-dims behavior.
        func frame(_ w: Int, _ h: Int) -> PixelFrame {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
            let b = pb!
            CVPixelBufferLockBaseAddress(b, [])
            if let base = CVPixelBufferGetBaseAddress(b) {
                memset(base, 100, CVPixelBufferGetBytesPerRow(b) * CVPixelBufferGetHeight(b))
            }
            CVPixelBufferUnlockBaseAddress(b, [])
            return PixelFrame(pixelBuffer: b, presentationTime: .zero)
        }
        func encDims(_ codec: AVVideoCodecType, _ ft: OutputContainer, _ w: Int, _ h: Int) async throws -> (Int, Int) {
            let out = tmpOut("odd", ft.ext); defer { try? FileManager.default.removeItem(at: out) }
            let sink = try AVAssetWriterVideoSink(destURL: out, codec: codec, fileType: ft.fileType, width: w, height: h)
            try sink.consume(frame(w, h)); try sink.finish()
            let (dw, dh, _) = try await dimsAndCount(out)
            return (dw, dh)
        }
        // ProRes / MJPEG: exact odd dims.
        let p = try await encDims(.proRes422, .mov, 1921, 1081)
        XCTAssertEqual(p.0, 1921); XCTAssertEqual(p.1, 1081)
        let m = try await encDims(.jpeg, .mov, 1921, 1081)
        XCTAssertEqual(m.0, 1921); XCTAssertEqual(m.1, 1081)
        // H.264: even-non-4 exact (1922×1082), odd silently rounded (this is
        // WHY the codec needs alignment 2 — the caller must keep dims even).
        let hEven = try await encDims(.h264, .mp4, 1922, 1082)
        XCTAssertEqual(hEven.0, 1922); XCTAssertEqual(hEven.1, 1082)
        let hOdd = try await encDims(.h264, .mp4, 1921, 1081)
        XCTAssertTrue(hOdd.0 % 2 == 0 && hOdd.1 % 2 == 0,
                      "VideoToolbox rounds odd H.264 dims to even (\(hOdd)) — hence alignment 2")
    }

    // MARK: - Motion JPEG (Phase 3)

    func testMJPEG_EncodesToMovWithJpegTag() async throws {
        let src = fixture("reference/fps/ntsc2997_h264.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "fixture missing")
        let (_, _, srcCount) = try await dimsAndCount(src)

        let out = tmpOut("mjpeg", "mov")
        defer { try? FileManager.default.removeItem(at: out) }
        try await encode(src, codec: .jpeg, container: .mov, out: out,
                         props: [AVVideoQualityKey: 0.85])

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        let tag = try await codecTag(out)
        XCTAssertEqual(tag, "jpeg", "MJPEG codec tag should be 'jpeg', got \(tag)")
        let (w, h, n) = try await dimsAndCount(out)
        XCTAssertGreaterThan(w, 0); XCTAssertGreaterThan(h, 0)
        XCTAssertEqual(n, srcCount, "MJPEG frame count \(n) != source \(srcCount)")
    }

    // MARK: - sustained-run footprint (VideoToolbox lifecycle)

    func testH264HEVCSustainedFootprintIsBounded() async throws {
        let src = fixture("reference/fps/clean30_h264.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "fixture missing: \(src.path)")

        var samples: [Double] = []
        let lock = NSLock()
        let runs: [(String, AVVideoCodecType)] = [
            ("h264-a", .h264), ("h264-b", .h264),
            ("hevc-a", .hevc), ("hevc-b", .hevc),
        ]
        for (name, codec) in runs {
            let out = tmpOut("fp-\(name)", "mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            let progress: EncodePipeline.ProgressCallback = { [weak self] _ in
                guard let self else { return }
                let mb = self.residentMB()
                lock.lock(); samples.append(mb); lock.unlock()
            }
            try await EncodePipeline(
                sourceURL: src,
                makeSink: { w, h, _ in
                    try AVAssetWriterVideoSink(
                        destURL: out, codec: codec, fileType: OutputContainer.mp4.fileType,
                        width: w, height: h)
                },
                progress: progress).run()
        }

        XCTAssertGreaterThan(samples.count, 300,
                             "expected several hundred samples, got \(samples.count)")
        let warmupCount = max(1, samples.count / 10)
        let warmupMax = samples.prefix(warmupCount).max() ?? 0
        let tailMax = samples.suffix(samples.count - warmupCount).max() ?? 0
        let growth = tailMax - warmupMax
        print("[vt-footprint] samples=\(samples.count) " +
              "min=\(String(format: "%.1f", samples.min() ?? 0))MB " +
              "max=\(String(format: "%.1f", samples.max() ?? 0))MB " +
              "warmupMax=\(String(format: "%.1f", warmupMax))MB " +
              "tailMax=\(String(format: "%.1f", tailMax))MB " +
              "growth=\(String(format: "%.1f", growth))MB")
        XCTAssertLessThan(growth, 250.0,
            "H.264/HEVC footprint grew \(growth)MB tail-vs-warmup — possible leak")
    }

    func testMJPEGSustainedFootprintIsBounded() async throws {
        let src = fixture("reference/fps/clean30_h264.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "fixture missing")

        var samples: [Double] = []
        let lock = NSLock()
        for run in ["mjpeg-a", "mjpeg-b", "mjpeg-c"] {
            let out = tmpOut("fp-\(run)", "mov")
            defer { try? FileManager.default.removeItem(at: out) }
            let progress: EncodePipeline.ProgressCallback = { [weak self] _ in
                guard let self else { return }
                let mb = self.residentMB()
                lock.lock(); samples.append(mb); lock.unlock()
            }
            try await EncodePipeline(
                sourceURL: src,
                makeSink: { w, h, _ in
                    try AVAssetWriterVideoSink(
                        destURL: out, codec: .jpeg, fileType: OutputContainer.mov.fileType,
                        width: w, height: h, compressionProperties: [AVVideoQualityKey: 0.85])
                },
                progress: progress).run()
        }
        XCTAssertGreaterThan(samples.count, 300, "got \(samples.count) samples")
        let warmupCount = max(1, samples.count / 10)
        let warmupMax = samples.prefix(warmupCount).max() ?? 0
        let tailMax = samples.suffix(samples.count - warmupCount).max() ?? 0
        let growth = tailMax - warmupMax
        print("[mjpeg-footprint] samples=\(samples.count) " +
              "min=\(String(format: "%.1f", samples.min() ?? 0))MB " +
              "max=\(String(format: "%.1f", samples.max() ?? 0))MB " +
              "growth=\(String(format: "%.1f", growth))MB")
        XCTAssertLessThan(growth, 250.0, "MJPEG footprint grew \(growth)MB — possible leak")
    }
}
