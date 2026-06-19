// SPDX-License-Identifier: MIT
import Foundation
import AVFoundation
import CoreVideo
import CoreMedia

/// Multi-format Phase 1 — the per-frame output seam. `EncodePipeline`'s
/// shared read → crop → resize → trim loop drives a `FrameSink`; the sink
/// owns "what happens to a finished `PixelFrame`."
///
/// Two implementations:
///   - `DXVEncoderSink` wraps the existing `FrameEncoder` + `PacketWriter`
///     pair (encode to DXV/HAP packet bytes, mux via the hand-rolled MOV
///     writer) — byte-for-byte identical to the pre-seam path.
///   - `AVAssetWriterVideoSink` feeds the `PixelFrame`'s `CVPixelBuffer`
///     straight to an `AVAssetWriterInputPixelBufferAdaptor` so
///     VideoToolbox encodes it (ProRes, H.264, HEVC, and Motion JPEG).
public protocol FrameSink: AnyObject {
    /// Consume one fully-transformed (cropped/resized) presentation frame.
    func consume(_ frame: PixelFrame) throws
    /// Flush + close the output. Called once after the last `consume`.
    func finish() throws
    /// Fix-Brief 2 (B) — non-fatal audio warning recorded during the run
    /// (e.g. the audio sample buffer couldn't be built, or the writer
    /// rejected the audio append). The video still completes; the caller
    /// reads this after `finish()` and surfaces it on the job. nil = audio
    /// fine / no audio. Defaulted nil for sinks that don't write audio here.
    var audioWarning: String? { get }
}

public extension FrameSink {
    var audioWarning: String? { nil }
}

/// Wraps the legacy encode→mux pair as a sink. Same encoder, same writer,
/// same bytes — the DXV3 byte-identity gate is the proof.
public final class DXVEncoderSink: FrameSink {
    private let encoder: FrameEncoder
    private let writer: PacketWriter
    /// Phase 4 — optional interleaved s32le source PCM + format. When set
    /// AND the writer is a VariantMOVWriter, a second audio trak is added.
    /// nil (the default — every existing call site, incl. the byte-gate
    /// tests) → exact pre-audio bytes.
    private let audio: (info: AudioStreamInfo, pcm: Data)?

    /// `encoder` must already be `prepare(...)`-d; `writer` already built.
    public init(encoder: FrameEncoder, writer: PacketWriter,
                audio: (info: AudioStreamInfo, pcm: Data)? = nil) {
        self.encoder = encoder
        self.writer = writer
        self.audio = audio
    }

    public func consume(_ frame: PixelFrame) throws {
        let encoded = try encoder.encode(frame: frame)
        try writer.append(packet: encoded, presentationTime: frame.presentationTime)
    }

    public func finish() throws {
        try encoder.finish()
        if let audio = audio, let vw = writer as? VariantMOVWriter {
            vw.attachAudioTrack(info: audio.info, pcm: audio.pcm)
        }
        try writer.finish()
    }
}

/// Build a single CMSampleBuffer holding all interleaved s32le PCM frames,
/// for appending to an AVAssetWriterInput (LPCM `.mov` or AAC `.mp4`).
/// Fix-Brief 2 (B) — THROWS on failure (was: returned nil, which the caller
/// silently turned into an empty audio trak). The caller catches and
/// surfaces a job warning while keeping the video.
func makeS32LEPCMSampleBuffer(_ pcm: Data, info: AudioStreamInfo) throws -> CMSampleBuffer {
    guard info.bytesPerFrame > 0, !pcm.isEmpty else {
        throw FrameSinkError.audioSampleBufferFailed("empty PCM or zero bytes-per-frame")
    }
    let frameCount = pcm.count / info.bytesPerFrame
    guard frameCount > 0 else {
        throw FrameSinkError.audioSampleBufferFailed("PCM shorter than one audio frame")
    }

    var asbd = AudioStreamBasicDescription(
        mSampleRate: Float64(info.sampleRate),
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, // LE (no BigEndian)
        mBytesPerPacket: UInt32(info.bytesPerFrame),
        mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(info.bytesPerFrame),
        mChannelsPerFrame: UInt32(info.channels),
        mBitsPerChannel: UInt32(info.bitsPerChannel),
        mReserved: 0)

    var fmt: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr,
          let format = fmt else {
        throw FrameSinkError.audioSampleBufferFailed(
            "CMAudioFormatDescriptionCreate rejected the format (channels=\(info.channels), rate=\(info.sampleRate))")
    }

    let len = pcm.count
    var bb: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
            memoryBlock: nil, blockLength: len, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: len,
            flags: 0, blockBufferOut: &bb) == noErr, let block = bb else {
        throw FrameSinkError.audioSampleBufferFailed("CMBlockBuffer allocation failed (\(len) bytes)")
    }
    let copyOK = pcm.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return false }
        return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
            offsetIntoDestination: 0, dataLength: len) == noErr
    }
    guard copyOK else {
        throw FrameSinkError.audioSampleBufferFailed("CMBlockBuffer data copy failed")
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(info.sampleRate)),
        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sizePerSample = info.bytesPerFrame
    var sb: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
            dataBuffer: block, formatDescription: format,
            sampleCount: frameCount, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &sizePerSample, sampleBufferOut: &sb) == noErr,
          let buffer = sb else {
        throw FrameSinkError.audioSampleBufferFailed("CMSampleBufferCreateReady failed")
    }
    return buffer
}

/// ProRes variants supported by AVAssetWriter/VideoToolbox (verified by
/// the Phase 1 diagnosis probe). `proRes4444` carries the source's BGRA
/// alpha straight through (yuva444p12le); the 422 family flattens alpha.
public enum ProResVariant: String, CaseIterable, Sendable, Hashable, Codable {
    case proRes422
    case proRes422HQ
    case proRes422LT
    case proRes422Proxy
    case proRes4444

    public var avCodec: AVVideoCodecType {
        switch self {
        case .proRes422:      return .proRes422
        case .proRes422HQ:    return .proRes422HQ
        case .proRes422LT:    return .proRes422LT
        case .proRes422Proxy: return .proRes422Proxy
        case .proRes4444:     return .proRes4444
        }
    }

    /// True only for 4444 — the only ProRes variant with an alpha plane.
    public var hasAlpha: Bool { self == .proRes4444 }

    /// QuickTime codec tag (apcn/apch/apcs/apco/ap4h) — for verification.
    public var codecTag: String {
        switch self {
        case .proRes422:      return "apcn"
        case .proRes422HQ:    return "apch"
        case .proRes422LT:    return "apcs"
        case .proRes422Proxy: return "apco"
        case .proRes4444:     return "ap4h"
        }
    }

    public var label: String {
        switch self {
        case .proRes422:      return "ProRes 422"
        case .proRes422HQ:    return "ProRes 422 HQ"
        case .proRes422LT:    return "ProRes 422 LT"
        case .proRes422Proxy: return "ProRes 422 Proxy"
        case .proRes4444:     return "ProRes 4444 (alpha)"
        }
    }

    /// Filename token for AutoNameEngine — like `label` but without the
    /// "(alpha)" parenthetical (filename-clean). e.g. "ProRes 4444".
    public var nameToken: String {
        switch self {
        case .proRes422:      return "ProRes 422"
        case .proRes422HQ:    return "ProRes 422 HQ"
        case .proRes422LT:    return "ProRes 422 LT"
        case .proRes422Proxy: return "ProRes 422 Proxy"
        case .proRes4444:     return "ProRes 4444"
        }
    }
}

public enum FrameSinkError: Error, CustomStringConvertible {
    case writerInitFailed(Error?)
    case codecRejected(String)
    case cannotAddInput
    case startWritingFailed(Error?)
    case appendFailed(presentationTime: CMTime)
    case finishFailed(status: Int, error: Error?)
    /// A requested audio track could not be added (e.g. AAC at an
    /// unsupported sample rate). Thrown — NEVER silently dropped — so a
    /// caller that asked to carry audio learns it didn't, rather than
    /// shipping a silent file. (EncodeQueue clamps AAC to ≤48 kHz upstream,
    /// so this is a defensive hard-error, not the normal path.)
    case audioInputRejected(rate: Int, container: String)
    /// Fix-Brief 2 (B) — the audio sample buffer could not be built (bad
    /// ASBD / allocation / CMSampleBuffer failure). Thrown by
    /// `makeS32LEPCMSampleBuffer`; the sink CATCHES it, records an
    /// `audioWarning`, and keeps the video — it does NOT fail the job.
    case audioSampleBufferFailed(String)

    public var description: String {
        switch self {
        case .writerInitFailed(let e): return "AVAssetWriter init failed: \(String(describing: e))"
        case .audioSampleBufferFailed(let s): return "audio sample buffer failed: \(s)"
        case .codecRejected(let s):    return "AVAssetWriter rejected codec/container: \(s)"
        case .cannotAddInput:          return "AVAssetWriter cannot add video input"
        case .startWritingFailed(let e): return "AVAssetWriter.startWriting failed: \(String(describing: e))"
        case .appendFailed(let pts):   return "pixel-buffer append failed at \(pts.seconds)s"
        case .finishFailed(let st, let e): return "AVAssetWriter.finishWriting status=\(st) err=\(String(describing: e))"
        case .audioInputRejected(let r, let c):
            return "AVAssetWriter rejected the audio input (\(r) Hz in \(c)) — audio would be dropped"
        }
    }
}

/// VideoToolbox-backed sink: appends the `PixelFrame`'s 32BGRA
/// `CVPixelBuffer` to an `AVAssetWriterInputPixelBufferAdaptor`. ProRes
/// 4444 preserves the BGRA alpha with no special property (diagnosis-
/// verified); the 422 family flattens it. Non-deterministic output — gated
/// by round-trip/structural + human checks, never byte-pinned.
public final class AVAssetWriterVideoSink: FrameSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false
    /// Phase 4 — optional audio input + the source PCM to feed it. LPCM
    /// for `.mov`, AAC for `.mp4` (AVAssetWriter encodes AAC natively). nil
    /// → no audio (output identical to the pre-audio path).
    private let audioInput: AVAssetWriterInput?
    private let audioData: (info: AudioStreamInfo, pcm: Data)?
    /// Fix-Brief 2 (B) — set if the audio could not be written (sample
    /// buffer build failed or the writer rejected the append) while the
    /// video still completes. The caller reads this after `finish()` and
    /// surfaces it as a non-fatal job warning. nil = audio fine / no audio.
    public private(set) var audioWarning: String?

    /// - Parameter compressionProperties: optional
    ///   `AVVideoCompressionPropertiesKey` payload (bitrate / quality /
    ///   keyframe / profile). Empty for ProRes (output unchanged from
    ///   Phase 1); populated for H.264 / HEVC (Phase 2a).
    /// - Parameter audio: optional interleaved s32le source PCM + format.
    ///   Added as a second track (LPCM for `.mov`, AAC for `.mp4`).
    public init(destURL: URL, codec: AVVideoCodecType, fileType: AVFileType,
                width: Int, height: Int,
                compressionProperties: [String: Any] = [:],
                audio: (info: AudioStreamInfo, pcm: Data)? = nil) throws {
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        do {
            writer = try AVAssetWriter(outputURL: destURL, fileType: fileType)
        } catch {
            throw FrameSinkError.writerInitFailed(error)
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if !compressionProperties.isEmpty {
            settings[AVVideoCompressionPropertiesKey] = compressionProperties
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw FrameSinkError.codecRejected("\(codec) in \(fileType.rawValue)")
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
        guard writer.canAdd(input) else { throw FrameSinkError.cannotAddInput }
        writer.add(input)

        // Phase 4 — optional audio track. LPCM for QuickTime; AAC for MPEG-4
        // (AVAssetWriter encodes AAC natively from the appended PCM — no
        // encoder dependency). Added before startWriting (first consume).
        if let audio = audio, audio.info.bytesPerFrame > 0, !audio.pcm.isEmpty {
            let aSettings: [String: Any]
            if fileType == .mp4 {
                aSettings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audio.info.sampleRate,
                    AVNumberOfChannelsKey: audio.info.channels,
                    AVEncoderBitRateKey: 256_000,
                ]
            } else {
                aSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: audio.info.sampleRate,
                    AVNumberOfChannelsKey: audio.info.channels,
                    AVLinearPCMBitDepthKey: audio.info.bitsPerChannel,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            }
            // NEVER silently drop a requested audio track. EncodeQueue
            // clamps AAC to ≤48 kHz upstream so canApply succeeds; if it
            // still fails here, fail loud rather than ship a silent file.
            guard writer.canApply(outputSettings: aSettings, forMediaType: .audio) else {
                throw FrameSinkError.audioInputRejected(
                    rate: audio.info.sampleRate, container: fileType.rawValue)
            }
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            ai.expectsMediaDataInRealTime = false
            guard writer.canAdd(ai) else {
                throw FrameSinkError.audioInputRejected(
                    rate: audio.info.sampleRate, container: fileType.rawValue)
            }
            writer.add(ai)
            audioInput = ai
            audioData = audio
        } else {
            // No audio requested (nil/empty) — legitimately no audio track.
            audioInput = nil
            audioData = nil
        }
    }

    private var audioFinished = false

    public func consume(_ frame: PixelFrame) throws {
        if !started {
            guard writer.startWriting() else {
                throw FrameSinkError.startWritingFailed(writer.error)
            }
            writer.startSession(atSourceTime: frame.presentationTime)
            started = true
            // Phase 4 — feed the ENTIRE audio track up front (one PCM
            // sample buffer) and finish the audio input immediately. With
            // two inputs, AVAssetWriter throttles each input's readiness to
            // keep them interleaved; if we fed all video before any audio,
            // the video input would stall waiting for audio (deadlock).
            // Finishing audio first lets video stream unblocked.
            if let ai = audioInput, let audio = audioData {
                // Fix-Brief 2 (B) — NEVER silently produce an empty audio
                // trak. If the sample buffer can't be built, or the writer
                // rejects/skips the append, record a warning (the caller
                // surfaces it on the job) and keep the video. Audio is fed
                // up front as one buffer, so the outcome is known here.
                do {
                    let sb = try makeS32LEPCMSampleBuffer(audio.pcm, info: audio.info)
                    waitReady(ai)
                    if ai.isReadyForMoreMediaData {
                        if !ai.append(sb) {
                            audioWarning = "Audio unavailable: writer rejected the audio (status \(writer.status.rawValue))"
                        }
                    } else {
                        audioWarning = "Audio unavailable: audio input never became ready"
                    }
                } catch {
                    audioWarning = "Audio unavailable: \(error)"
                }
                ai.markAsFinished()
                audioFinished = true
            } else if let ai = audioInput {
                ai.markAsFinished()
                audioFinished = true
            }
        }
        // Encode is not real-time; spin until the input drains (bounded by
        // writer health so a failed writer can't hang forever).
        waitReady(input)
        guard adaptor.append(frame.pixelBuffer, withPresentationTime: frame.presentationTime) else {
            throw FrameSinkError.appendFailed(presentationTime: frame.presentationTime)
        }
    }

    /// Spin until the input is ready, the writer fails, or a generous
    /// timeout — never an unbounded hang.
    private func waitReady(_ inp: AVAssetWriterInput) {
        var spins = 0
        while !inp.isReadyForMoreMediaData && writer.status == .writing && spins < 60_000 {
            Thread.sleep(forTimeInterval: 0.001)
            spins += 1
        }
    }

    public func finish() throws {
        if let ai = audioInput, !audioFinished { ai.markAsFinished() }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else {
            throw FrameSinkError.finishFailed(status: writer.status.rawValue, error: writer.error)
        }
    }
}
