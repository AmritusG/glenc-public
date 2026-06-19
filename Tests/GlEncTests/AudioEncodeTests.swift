/*
 * Multi-Format Phase 4 — audio pass-through tests. Structural/round-trip
 * (audio output is non-deterministic for the delivery codecs); the DXV
 * audio trak is introspected via AVFoundation (it parses the container
 * even though it can't decode DXV video). The video byte-identity-when-
 * absent guarantee is covered by the 8 named DXV gate tests.
 */
import XCTest
import AVFoundation
import CoreMedia
import Darwin
@testable import GlEncCore

final class AudioEncodeTests: XCTestCase {

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
    private func tmp(_ n: String, _ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-audio-\(n)-\(UUID().uuidString).\(ext)")
    }
    private func fourcc(_ s: FourCharCode) -> String {
        let b = [UInt8((s >> 24) & 0xff), UInt8((s >> 16) & 0xff), UInt8((s >> 8) & 0xff), UInt8(s & 0xff)]
        return String(bytes: b, encoding: .ascii) ?? "----"
    }
    private func trackCounts(_ url: URL) async throws -> (video: Int, audio: Int) {
        let a = AVURLAsset(url: url)
        let v = (try? await a.loadTracks(withMediaType: .video)) ?? []
        let au = (try? await a.loadTracks(withMediaType: .audio)) ?? []
        return (v.count, au.count)
    }
    private func audioASBD(_ url: URL) async throws -> (subtype: String, channels: Int, rate: Int, formatID: AudioFormatID, bits: Int)? {
        let a = AVURLAsset(url: url)
        guard let t = try await a.loadTracks(withMediaType: .audio).first,
              let f = try await t.load(.formatDescriptions).first else { return nil }
        let st = CMFormatDescriptionGetMediaSubType(f)
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee
        return (fourcc(st), Int(asbd?.mChannelsPerFrame ?? 0), Int(asbd?.mSampleRate ?? 0),
                asbd?.mFormatID ?? 0, Int(asbd?.mBitsPerChannel ?? 0))
    }

    // MARK: - DXV audio trak (in32) via VariantMOVWriter

    func testDXVAudioTrak_in32_StereoPreserved() async throws {
        let out = tmp("dxv-aud", "mov")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try VariantMOVWriter(
            destURL: out, format: .dxt1, presentationWidth: 1920,
            presentationHeight: 1080, fps: 30, codecFourCC: "DXD3")
        for _ in 0..<5 { try writer.append(packet: Data(repeating: 0xAB, count: 4096), presentationTime: .zero) }
        // 0.5s stereo 48k 32-bit PCM
        let info = AudioStreamInfo(sampleRate: 48000, channels: 2, bitsPerChannel: 32)
        let frames = 24000
        writer.attachAudioTrack(info: info, pcm: Data(repeating: 0, count: frames * info.bytesPerFrame))
        try writer.finish()

        let (v, au) = try await trackCounts(out)
        XCTAssertEqual(v, 1, "video trak present")
        XCTAssertEqual(au, 1, "audio trak present")
        // AVFoundation normalizes any PCM variant to 'lpcm'; the on-disk
        // format code is the real Alley-match signal.
        let a = try await audioASBD(out)
        XCTAssertEqual(a?.formatID, kAudioFormatLinearPCM, "parses as LPCM")
        XCTAssertEqual(a?.channels, 2)
        XCTAssertEqual(a?.rate, 48000)
        XCTAssertEqual(a?.bits, 32, "32-bit (in32)")
        let raw = try Data(contentsOf: out)
        XCTAssertNotNil(raw.range(of: Data("in32".utf8)),
                        "stsd carries the Alley 'in32' format code on disk")
    }

    func testDXVAudio_HighRate96k_UsesV2_CorrectRate() async throws {
        // Regression: the V1 16.16 sample-rate field overflowed for ≥65536 Hz
        // (96000 → ~30464), which made audio play slow with artifacts. High
        // rates now use SoundDescription V2 (lpcm) with a Float64 rate.
        for (rate, ch) in [(88200, 2), (96000, 1)] {
            let out = tmp("dxv-\(rate)", "mov")
            defer { try? FileManager.default.removeItem(at: out) }
            let writer = try VariantMOVWriter(
                destURL: out, format: .dxt1, presentationWidth: 1920,
                presentationHeight: 1080, fps: 30, codecFourCC: "DXD3")
            for _ in 0..<5 { try writer.append(packet: Data(repeating: 0xAB, count: 4096), presentationTime: .zero) }
            let info = AudioStreamInfo(sampleRate: rate, channels: ch, bitsPerChannel: 32)
            writer.attachAudioTrack(info: info, pcm: Data(count: rate * info.bytesPerFrame))  // 1.0s
            try writer.finish()

            let a = try await audioASBD(out)
            XCTAssertEqual(a?.formatID, kAudioFormatLinearPCM)
            XCTAssertEqual(a?.rate, rate, "high-rate \(rate) must report exactly (V2), not the V1-overflow garbage")
            XCTAssertEqual(a?.channels, ch)
            // duration ~1.0s (frameCount/rate) — proves no slow-down.
            let dur = try await CMTimeGetSeconds(AVURLAsset(url: out).load(.duration))
            XCTAssertEqual(dur, 1.0, accuracy: 0.05, "duration must be ~1s (no rate-mismatch stretch)")
        }
    }

    func testDXVStrip_NoAudioTrack() async throws {
        let out = tmp("dxv-noaud", "mov")
        defer { try? FileManager.default.removeItem(at: out) }
        let writer = try VariantMOVWriter(
            destURL: out, format: .dxt1, presentationWidth: 1920,
            presentationHeight: 1080, fps: 30, codecFourCC: "DXD3")
        for _ in 0..<5 { try writer.append(packet: Data(repeating: 0xAB, count: 4096), presentationTime: .zero) }
        // no attachAudioTrack
        try writer.finish()
        let (v, au) = try await trackCounts(out)
        XCTAssertEqual(v, 1)
        XCTAssertEqual(au, 0, "stripped/absent audio → no audio trak (byte-identical path)")
    }

    // MARK: - delivery codecs: LPCM in .mov, AAC in .mp4

    func testDeliveryAudio_MovLPCM_and_Mp4AAC() async throws {
        let src = fixture("reference/hap-audio/sample-with-audio.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "audio fixture missing")
        guard let read = try await SourceAudioReader.readInterleavedPCM(src, targetRate: nil) else {
            return XCTFail("source has no audio")
        }
        let audio = (read.info, read.pcm)

        // ProRes .mov → LPCM
        let mov = tmp("prores", "mov")
        defer { try? FileManager.default.removeItem(at: mov) }
        try await EncodePipeline(sourceURL: src, makeSink: { w, h, _ in
            try AVAssetWriterVideoSink(destURL: mov, codec: .proRes422, fileType: .mov,
                                       width: w, height: h, audio: audio)
        }).run()
        let movA = try await audioASBD(mov)
        XCTAssertNotNil(movA, ".mov must have an audio track")
        XCTAssertEqual(movA?.formatID, kAudioFormatLinearPCM, ".mov audio = LPCM")

        // H.264 .mp4 → AAC
        let mp4 = tmp("h264", "mp4")
        defer { try? FileManager.default.removeItem(at: mp4) }
        try await EncodePipeline(sourceURL: src, makeSink: { w, h, _ in
            try AVAssetWriterVideoSink(destURL: mp4, codec: .h264, fileType: .mp4,
                                       width: w, height: h, audio: audio)
        }).run()
        let mp4A = try await audioASBD(mp4)
        XCTAssertNotNil(mp4A, ".mp4 must have an audio track")
        XCTAssertEqual(mp4A?.formatID, kAudioFormatMPEG4AAC, ".mp4 audio = AAC")
    }

    // MARK: - AAC/.mp4 high-rate clamp (the silent-drop fix)

    func testAACmp4_HighRate_ClampsTo48k_NotDropped() async throws {
        let src = fixture("reference/hap-audio/sample-with-audio.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "fixture missing")
        // EncodeQueue clamps the requested rate to the container's max for AAC.
        let cap = OutputContainer.mp4.maxAudioSampleRate            // 48000
        let target = min(96000, cap)                               // 48000
        XCTAssertEqual(target, 48000, "AAC/.mp4 must clamp 96k → 48k")
        guard let read = try await SourceAudioReader.readInterleavedPCM(src, targetRate: target) else {
            return XCTFail("no source audio")
        }
        let out = tmp("aac48", "mp4"); defer { try? FileManager.default.removeItem(at: out) }
        try await EncodePipeline(sourceURL: src, makeSink: { w, h, _ in
            try AVAssetWriterVideoSink(destURL: out, codec: .h264, fileType: .mp4,
                                       width: w, height: h, audio: (read.info, read.pcm))
        }).run()
        let a = try await audioASBD(out)
        XCTAssertNotNil(a, "H.264/.mp4 + high-rate audio must NOT be dropped")
        XCTAssertEqual(a?.formatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(a?.rate, 48000, "carried at the clamped 48k")
    }

    func testAACmp4_UnclampedHighRate_ThrowsNotSilent() async throws {
        // Defensive: if a >48k rate reaches the AAC sink (clamp bypassed),
        // the sink THROWS (audioInputRejected) — never silently drops.
        let src = fixture("reference/hap-audio/sample-with-audio.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "fixture missing")
        guard let read = try await SourceAudioReader.readInterleavedPCM(src, targetRate: 96000) else {
            return XCTFail("no source audio")
        }
        let out = tmp("aac96-throw", "mp4"); defer { try? FileManager.default.removeItem(at: out) }
        do {
            try await EncodePipeline(sourceURL: src, makeSink: { w, h, _ in
                try AVAssetWriterVideoSink(destURL: out, codec: .h264, fileType: .mp4,
                                           width: w, height: h, audio: (read.info, read.pcm))
            }).run()
            XCTFail("expected a hard error, not a silent audio drop")
        } catch let e as FrameSinkError {
            if case .audioInputRejected = e {} else { XCTFail("wrong FrameSinkError: \(e)") }
        }
    }

    func testMovLPCM_96k_StillCarried_Regression() async throws {
        // The working path must be unchanged: .mov LPCM carries 96k.
        let src = fixture("reference/hap-audio/sample-with-audio.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "fixture missing")
        guard let read = try await SourceAudioReader.readInterleavedPCM(src, targetRate: 96000) else {
            return XCTFail("no source audio")
        }
        let out = tmp("lpcm96", "mov"); defer { try? FileManager.default.removeItem(at: out) }
        try await EncodePipeline(sourceURL: src, makeSink: { w, h, _ in
            try AVAssetWriterVideoSink(destURL: out, codec: .proRes422, fileType: .mov,
                                       width: w, height: h, audio: (read.info, read.pcm))
        }).run()
        let a = try await audioASBD(out)
        XCTAssertEqual(a?.formatID, kAudioFormatLinearPCM)
        XCTAssertEqual(a?.rate, 96000, ".mov LPCM still carries 96k unchanged")
    }

    // MARK: - resample + probe

    func testResampleHonorsTargetRate() async throws {
        let src = fixture("reference/hap-audio/sample-with-audio.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "audio fixture missing")
        let orig = try await SourceAudioReader.readInterleavedPCM(src, targetRate: nil)
        let at48 = try await SourceAudioReader.readInterleavedPCM(src, targetRate: 48000)
        XCTAssertNotNil(orig); XCTAssertNotNil(at48)
        XCTAssertEqual(at48?.info.sampleRate, 48000, "explicit 48k honored")
        // source is 44.1k → resample changes the rate
        XCTAssertNotEqual(orig?.info.sampleRate, 48000, "Original keeps source rate (44.1k)")
    }

    // MARK: - sustained-run footprint with audio attached

    func testAudioFootprintBounded() async throws {
        let src = fixture("reference/fps/clean30_h264.mp4")   // 150 frames, 30fps
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "fixture missing")
        // Synthetic 5s stereo 48k 32-bit PCM (the buffer under test).
        let info = AudioStreamInfo(sampleRate: 48000, channels: 2, bitsPerChannel: 32)
        let pcm = Data(count: 48000 * info.bytesPerFrame * 5)

        var samples: [Double] = []
        let lock = NSLock()
        func sample(_ p: Double) { let mb = residentMB(); lock.lock(); samples.append(mb); lock.unlock() }

        for run in 0..<3 {
            // DXV+audio
            let dxvOut = tmp("fp-dxv\(run)", "mov")
            defer { try? FileManager.default.removeItem(at: dxvOut) }
            try await EncodePipeline(sourceURL: src, makeSink: { w, h, fps in
                let enc = DXT1Encoder()
                try enc.prepare(width: w, height: h, fps: fps, hasAlpha: false)
                let writer = try VariantMOVWriter(destURL: dxvOut, format: .dxt1,
                    presentationWidth: w, presentationHeight: h, fps: fps, codecFourCC: "DXD3")
                return DXVEncoderSink(encoder: enc, writer: writer, audio: (info, pcm))
            }, progress: { sample($0) }, sourceAlphaInfo: .noneSkipLast).run()

            // ProRes+audio
            let prOut = tmp("fp-pr\(run)", "mov")
            defer { try? FileManager.default.removeItem(at: prOut) }
            try await EncodePipeline(sourceURL: src, makeSink: { w, h, _ in
                try AVAssetWriterVideoSink(destURL: prOut, codec: .proRes422, fileType: .mov,
                    width: w, height: h, audio: (info, pcm))
            }, progress: { sample($0) }).run()
        }

        XCTAssertGreaterThan(samples.count, 300, "got \(samples.count)")
        let warmupMax = samples.prefix(max(1, samples.count/10)).max() ?? 0
        let tailMax = samples.suffix(samples.count - max(1, samples.count/10)).max() ?? 0
        let growth = tailMax - warmupMax
        print("[audio-footprint] samples=\(samples.count) " +
              "min=\(String(format: "%.1f", samples.min() ?? 0))MB " +
              "max=\(String(format: "%.1f", samples.max() ?? 0))MB growth=\(String(format: "%.1f", growth))MB")
        XCTAssertLessThan(growth, 250.0, "audio-path footprint grew \(growth)MB — possible accumulation")
    }

    func testHasAudioProbe() async throws {
        let withAudio = fixture("reference/hap-audio/sample-with-audio.mov")
        let videoOnly = fixture("reference/dxt1/ffmpeg.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: withAudio.path) &&
                          FileManager.default.fileExists(atPath: videoOnly.path), "fixtures missing")
        let a = await SourceAudioReader.hasAudio(withAudio)
        let b = await SourceAudioReader.hasAudio(videoOnly)
        XCTAssertTrue(a, "sample-with-audio has audio")
        XCTAssertFalse(b, "ffmpeg.mov (testsrc DXV) is video-only")
    }
}
