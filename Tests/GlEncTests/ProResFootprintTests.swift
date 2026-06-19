/*
 * Multi-Format Phase 1 — sustained-run footprint gate for the
 * VideoToolbox sink. AVAssetWriter / pixel-buffer-adaptor lifecycles
 * are the leak risk (cf. the v0.10.1 HAP-decode leak — point-in-time
 * tests can't catch a per-frame accumulation). This encodes a 150-frame
 * source to ProRes 422 and 4444, several runs each (~600 frame-appends
 * total), sampling RSS via the per-frame progress callback, and asserts
 * the curve is bounded — no monotonic per-frame/per-session growth.
 */
import XCTest
import AVFoundation
import Darwin
@testable import GlEncCore

final class ProResFootprintTests: XCTestCase {

    private func fixture(_ rel: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(rel)
    }

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

    func testProResSustainedFootprintIsBounded() async throws {
        let src = fixture("reference/fps/clean30_h264.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "fixture missing: \(src.path)")

        var samples: [Double] = []
        let lock = NSLock()

        let runs: [(String, ProResVariant)] = [
            ("422-a", .proRes422), ("422-b", .proRes422),
            ("4444-a", .proRes4444), ("4444-b", .proRes4444),
        ]

        for (name, variant) in runs {
            let out = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("glenc-footprint-\(name)-\(UUID().uuidString).mov")
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
                        destURL: out, codec: variant.avCodec,
                        fileType: .mov, width: w, height: h)
                },
                progress: progress).run()
        }

        XCTAssertGreaterThan(samples.count, 300,
                             "expected several hundred per-frame samples, got \(samples.count)")

        // Warmup window = first 10% of samples; compare the tail to it.
        let warmupCount = max(1, samples.count / 10)
        let warmupMax = samples.prefix(warmupCount).max() ?? 0
        let tailMax = samples.suffix(samples.count - warmupCount).max() ?? 0
        let overallMin = samples.min() ?? 0
        let overallMax = samples.max() ?? 0
        let growth = tailMax - warmupMax

        print("[prores-footprint] samples=\(samples.count) " +
              "min=\(String(format: "%.1f", overallMin))MB " +
              "max=\(String(format: "%.1f", overallMax))MB " +
              "warmupMax=\(String(format: "%.1f", warmupMax))MB " +
              "tailMax=\(String(format: "%.1f", tailMax))MB " +
              "growth(tail-warmup)=\(String(format: "%.1f", growth))MB")

        // A real per-frame/per-session leak (cf. HAP's ~105 MB/sec) would
        // blow far past this over ~600 appends + 4 sink lifecycles. A
        // bounded working set drifts only modestly. 250 MB is generous
        // headroom while still catching genuine accumulation.
        XCTAssertLessThan(growth, 250.0,
            "ProRes footprint grew \(growth)MB tail-vs-warmup — possible leak")
    }
}
