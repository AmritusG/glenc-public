// SPDX-License-Identifier: MIT
import Foundation
import AVFoundation
import CoreMedia

/// Stage A (DXV audio-master): the audio engine that owns the canonical
/// playback timeline. The video `FrameClock` follows the position this
/// type reports (see `FrameClock.audioTimeSource`). Audio is the master;
/// video is scheduled against it.
///
/// Design notes / guardrails (the §-numbers refer to the arc guardrails):
/// - §2 The REAL sample rate + channel count are read from the decoded
///   track's stream format (the ASBD of the `AVAssetReader` output) —
///   never assumed 48k.
/// - §3 The format is validated at the trust boundary: channels clamped
///   to [1, 64], sample rate required finite and > 0; anything else
///   throws a typed `AudioClockError` rather than being trusted.
/// - §4 The throwing initializer is `defer`-guarded so a mid-setup throw
///   tears down anything partially acquired (engine/node); `deinit`
///   stops the engine and detaches the node. No stranded engine on any
///   path.
///
/// Loading mechanism: **`AVAssetReader`**, not `AVAudioFile`.
/// `AVAudioFile` targets plain audio containers (caf/wav/m4a/…) and does
/// not reliably open the audio track of a `.mov` *video* container;
/// `AVAssetReader` is the robust path for extracting the PCM audio track
/// out of a DXV `.mov`.
///
/// Buffering: the whole track is decoded into one in-memory
/// `AVAudioPCMBuffer` (non-interleaved Float32). For the Stage-A fixture
/// (~13.4 s stereo 48k ≈ 5 MB) this is trivial and gives sample-accurate
/// seek/loop by slicing the buffer. For pathologically long clips a
/// chunked/streaming scheduler would be the fallback; that is not needed
/// for this stage and is intentionally not built here.
///
/// Threading: every method is called from the main thread (DXVPlayer's
/// transport and the `FrameClock` tick both run on main). The position
/// read (`currentSeconds`) only touches `AVAudioPlayerNode` timing APIs,
/// which are safe to call from any thread.
enum AudioClockError: Error, CustomStringConvertible {
    /// The container has no audio track at all. Not a failure — the
    /// caller continues video-only and records `.none`.
    case noAudioTrack
    /// The audio format failed the §3 trust-boundary validation.
    case invalidFormat(String)
    /// The track exists but could not be read/decoded.
    case unreadable(String)

    var description: String {
        switch self {
        case .noAudioTrack: return "no audio track"
        case .invalidFormat(let r): return "invalid audio format: \(r)"
        case .unreadable(let r): return "audio unreadable: \(r)"
        }
    }
}

final class AudioClock {
    /// REAL sample rate read from the track (§2). Never assumed.
    let sampleRate: Double
    /// REAL channel count read from the track (§2), validated to [1,64].
    let channelCount: Int

    /// Audio track duration in seconds (the loop length). Used by
    /// DXVPlayer to detect an audio/video length mismatch (Item 2 §5).
    var durationSeconds: Double {
        sampleRate > 0 ? Double(totalAudioFrames) / sampleRate : 0
    }

    // MARK: - Output gain (Stage D — GAIN ONLY, never moves the clock)

    /// Output gain, linear, clamped to [0, 1] on apply. Default 1.0. Setting
    /// it applies the effective gain (`isMuted ? 0 : volume`) to the player
    /// node. The defaults are set during init (observers don't fire then), so
    /// no gain is applied until a consumer changes it.
    var volume: Float = 1.0 {
        didSet { applyGain() }
    }
    /// Mute toggle, SEPARATE from `volume` so unmute restores the prior
    /// level. Default false. Effective node gain = `isMuted ? 0 : volume`.
    var isMuted: Bool = false {
        didSet { applyGain() }
    }

    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    /// Full decoded PCM (non-interleaved Float32) at the file sample rate.
    private let fullBuffer: AVAudioPCMBuffer
    private let totalAudioFrames: Int

    /// Whether audio loops at end-of-stream. Mirrors the video clock's
    /// `loops`; kept in lockstep by `DXVPlayer.setLoops`.
    private var loops: Bool
    /// File-frame index that the player node's sample-time 0 maps to for
    /// the current schedule (updated on every (re)schedule / seek).
    private var baseFileFrame: Int = 0
    /// Deferred start position: set by `seek(toSeconds:)` while paused so
    /// we don't reschedule (and memcpy a slice) on every scrub tick;
    /// materialized by `play()`. Non-nil means "schedule from here next".
    private var pendingStartFrame: Int? = 0

    // MARK: - Init

    /// Build the audio clock for `url`. Throws `AudioClockError` on no
    /// audio track / invalid format / unreadable audio. §4: defer-guarded
    /// so a throw after engine creation tears the engine/node down.
    init(url: URL, loops: Bool) throws {
        self.loops = loops

        #if os(iOS)
        // iOS requires an active playback session before the engine
        // starts. macOS has no AVAudioSession. (Not runtime-validated on
        // iOS this stage — compile-only.)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
        #endif

        let asset = AVURLAsset(url: url)
        let track = try Self.firstAudioTrack(asset)
        let decoded = try Self.decodeFullPCM(asset: asset, track: track)

        // Engine wiring is the only thing that can strand a resource, so
        // it goes last behind the defer guard (§4).
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        var committed = false
        defer {
            if !committed {
                node.stop()
                engine.stop()
                engine.detach(node)
            }
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: decoded.buffer.format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioClockError.unreadable("engine start failed: \(error.localizedDescription)")
        }

        self.engine = engine
        self.playerNode = node
        self.fullBuffer = decoded.buffer
        self.totalAudioFrames = Int(decoded.buffer.frameLength)
        self.sampleRate = decoded.sampleRate
        self.channelCount = decoded.channels
        committed = true
    }

    deinit {
        // §4 explicit teardown — never rely on stop() having been called.
        playerNode.stop()
        engine.stop()
        engine.detach(playerNode)
    }

    // MARK: - Position (sample-accurate, derived from the node sample time)

    /// Current playback position in seconds within the file, wrapped to
    /// [0, duration) when looping. Returns nil until the node has a valid
    /// render time (i.e. until playback is primed) so the caller can hold
    /// the current frame rather than guess.
    func currentSeconds() -> Double? {
        guard let renderTime = playerNode.lastRenderTime,
              renderTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else {
            return nil
        }
        return Self.wrappedPositionSeconds(baseFileFrame: baseFileFrame,
                                           nodeSamples: Double(playerTime.sampleTime),
                                           totalAudioFrames: totalAudioFrames,
                                           sampleRate: sampleRate,
                                           loops: loops)
    }

    /// Pure within-loop position math, extracted so it is unit-testable
    /// without a live `AVAudioPlayerNode`. Returns the position in seconds
    /// within the file, wrapped to [0, duration) when looping (so the loop
    /// seam is continuous), clamped to the last frame when not. Returns nil
    /// for invalid inputs (negative samples / empty buffer / bad rate).
    static func wrappedPositionSeconds(baseFileFrame: Int,
                                       nodeSamples: Double,
                                       totalAudioFrames: Int,
                                       sampleRate: Double,
                                       loops: Bool) -> Double? {
        if nodeSamples < 0 { return nil }
        let total = Double(totalAudioFrames)
        guard total > 0, sampleRate > 0 else { return nil }
        let absFrames = Double(baseFileFrame) + nodeSamples
        let wrapped = loops
            ? absFrames.truncatingRemainder(dividingBy: total)
            : min(absFrames, total - 1)
        return wrapped / sampleRate
    }

    // MARK: - Transport

    /// Start (or resume) audio playback. Returns `false` if the engine
    /// could not be started — Item 1 §1: the caller MUST react (fall back
    /// to the wall clock + surface the failure) rather than freeze video on
    /// a clock that will never advance.
    @discardableResult
    func play() -> Bool {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                return false
            }
        }
        if let frame = pendingStartFrame {
            scheduleFrom(frame: frame)
            pendingStartFrame = nil
        }
        playerNode.play()
        return true
    }

    func pause() {
        // Keeps the schedule + node sample time frozen; play() resumes.
        playerNode.pause()
    }

    /// Reposition audio to `seconds`. While playing, reschedules and
    /// resumes immediately; while paused, defers the (memcpy-ing)
    /// reschedule until the next `play()` so scrub-drags don't thrash.
    func seek(toSeconds seconds: Double) {
        let frame = clampFrame(Int((seconds * sampleRate).rounded()))
        if playerNode.isPlaying {
            scheduleFrom(frame: frame)
            playerNode.play()
            pendingStartFrame = nil
        } else {
            pendingStartFrame = frame
        }
    }

    /// Mirror the video clock's loop state. Reschedules from the current
    /// position so the looping tail is added/removed.
    func setLoops(_ on: Bool) {
        guard on != loops else { return }
        loops = on
        let frame: Int
        if let cur = currentSeconds() {
            frame = clampFrame(Int((cur * sampleRate).rounded()))
        } else {
            frame = baseFileFrame
        }
        if playerNode.isPlaying {
            scheduleFrom(frame: frame)
            playerNode.play()
            pendingStartFrame = nil
        } else {
            pendingStartFrame = frame
        }
    }

    func stop() {
        playerNode.stop()
        engine.stop()
    }

    /// Apply the effective output gain to the player node. GAIN ONLY: this
    /// sets ONLY `playerNode.volume`. It does NOT stop, pause, reschedule, or
    /// re-anchor the node, and it does NOT touch the sample-time position that
    /// `currentSeconds()` reads as the master clock — the player node's sample
    /// time advances identically at gain 0 or 1. So a MUTED clip keeps
    /// rendering (sample time advancing) and stays in perfect video sync; it
    /// is silent, not stopped.
    private func applyGain() {
        playerNode.volume = Self.effectiveGain(volume: volume, muted: isMuted)
    }

    /// Pure gain contract, extracted for unit testing without a live engine:
    /// muted → 0; otherwise `volume` clamped to [0, 1].
    static func effectiveGain(volume: Float, muted: Bool) -> Float {
        muted ? 0.0 : min(1.0, max(0.0, volume))
    }

    // MARK: - Scheduling

    /// Schedule playback starting at file frame `frame`. Plays the tail
    /// [frame, end) once, then — if looping — the full buffer forever.
    /// The combination makes `(baseFileFrame + nodeSampleTime) % total`
    /// track the true file position continuously across the loop seam.
    private func scheduleFrom(frame: Int) {
        playerNode.stop()  // clears pending buffers + resets node sample time
        let start = clampFrame(frame)
        baseFileFrame = start
        let tail = slice(from: start)
        playerNode.scheduleBuffer(tail, at: nil, options: [], completionHandler: nil)
        if loops {
            playerNode.scheduleBuffer(fullBuffer, at: nil, options: .loops, completionHandler: nil)
        }
    }

    /// A new PCM buffer containing frames [frame, end) of `fullBuffer`.
    private func slice(from frame: Int) -> AVAudioPCMBuffer {
        let count = max(1, totalAudioFrames - frame)
        let out = AVAudioPCMBuffer(pcmFormat: fullBuffer.format,
                                   frameCapacity: AVAudioFrameCount(count))!
        out.frameLength = AVAudioFrameCount(count)
        let ch = Int(fullBuffer.format.channelCount)
        if let srcData = fullBuffer.floatChannelData, let dstData = out.floatChannelData {
            for c in 0..<ch {
                dstData[c].update(from: srcData[c] + frame, count: count)
            }
        }
        return out
    }

    private func clampFrame(_ f: Int) -> Int {
        max(0, min(totalAudioFrames - 1, f))
    }

    // MARK: - Decode (AVAssetReader → one non-interleaved Float32 buffer)

    private static func firstAudioTrack(_ asset: AVURLAsset) throws -> AVAssetTrack {
        // Bridge the async `loadTracks` to the synchronous throwing init.
        // The completion fires on an AVFoundation-internal queue (never
        // the calling thread), so waiting on the semaphore is deadlock-
        // free even on main.
        let sem = DispatchSemaphore(value: 0)
        var result: Result<AVAssetTrack?, Error> = .success(nil)
        asset.loadTracks(withMediaType: .audio) { tracks, error in
            if let error = error {
                result = .failure(error)
            } else {
                result = .success(tracks?.first)
            }
            sem.signal()
        }
        sem.wait()
        switch result {
        case .failure(let e):
            throw AudioClockError.unreadable("track load failed: \(e.localizedDescription)")
        case .success(let track):
            guard let track = track else { throw AudioClockError.noAudioTrack }
            return track
        }
    }

    private struct DecodedAudio {
        let buffer: AVAudioPCMBuffer
        let sampleRate: Double
        let channels: Int
    }

    /// §3 trust-boundary validation, extracted so it is unit-testable
    /// without a live engine. Channels must be in [1,64]; sample rate must
    /// be finite and > 0. Throws `AudioClockError.invalidFormat` on garbage
    /// rather than trusting the header.
    static func validateAudioFormat(sampleRate: Double, channels: Int) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AudioClockError.invalidFormat("non-finite or zero sample rate (\(sampleRate))")
        }
        guard channels >= 1, channels <= 64 else {
            throw AudioClockError.invalidFormat("channel count \(channels) out of [1,64]")
        }
    }

    private static func decodeFullPCM(asset: AVURLAsset, track: AVAssetTrack) throws -> DecodedAudio {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioClockError.unreadable("reader init failed: \(error.localizedDescription)")
        }
        // Request LPCM Float32, non-interleaved, native sample rate +
        // channel count (no AVSampleRateKey / AVNumberOfChannelsKey ->
        // no resample, no down/up-mix) so we read the REAL format (§2).
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioClockError.unreadable("cannot add reader output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioClockError.unreadable("reader start failed: \(reader.error?.localizedDescription ?? "unknown")")
        }

        var sr: Double = 0
        var ch: Int = 0
        var planes: [[Float]] = []

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            if ch == 0 {
                guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else {
                    throw AudioClockError.invalidFormat("missing audio format description")
                }
                let asbd = asbdPtr.pointee
                sr = asbd.mSampleRate
                ch = Int(asbd.mChannelsPerFrame)
                // §3 validate at the trust boundary — do NOT trust the header.
                try validateAudioFormat(sampleRate: sr, channels: ch)
                planes = Array(repeating: [Float](), count: ch)
            }
            try appendSamples(sampleBuffer, channels: ch, into: &planes)
        }
        if reader.status == .failed {
            throw AudioClockError.unreadable("reader failed: \(reader.error?.localizedDescription ?? "unknown")")
        }
        guard ch > 0, let total = planes.first?.count, total > 0 else {
            throw AudioClockError.unreadable("no audio samples decoded")
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr,
                                         channels: AVAudioChannelCount(ch)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(total)) else {
            throw AudioClockError.invalidFormat("could not build audio buffer (sr=\(sr) ch=\(ch))")
        }
        buffer.frameLength = AVAudioFrameCount(total)
        if let dst = buffer.floatChannelData {
            for c in 0..<ch {
                planes[c].withUnsafeBufferPointer { src in
                    dst[c].update(from: src.baseAddress!, count: total)
                }
            }
        }
        return DecodedAudio(buffer: buffer, sampleRate: sr, channels: ch)
    }

    /// Copy one CMSampleBuffer's PCM into the per-channel accumulators.
    /// Handles both non-interleaved (one ABL buffer per channel — what we
    /// requested) and an interleaved fallback, for robustness.
    private static func appendSamples(_ sampleBuffer: CMSampleBuffer,
                                      channels ch: Int,
                                      into planes: inout [[Float]]) throws {
        let frames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return }

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil)

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else {
            throw AudioClockError.unreadable("audio buffer list copy failed (\(status))")
        }

        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        if abl.count >= ch {
            // Non-interleaved: one buffer per channel, `frames` floats each.
            for c in 0..<ch {
                guard let mData = abl[c].mData else { continue }
                let fptr = mData.assumingMemoryBound(to: Float.self)
                planes[c].append(contentsOf: UnsafeBufferPointer(start: fptr, count: frames))
            }
        } else if abl.count == 1 {
            // Interleaved fallback: de-interleave channel-major.
            guard let mData = abl[0].mData else { return }
            let fptr = mData.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                for c in 0..<ch {
                    planes[c].append(fptr[f * ch + c])
                }
            }
        }
        // Keep the retained block buffer alive until the copies above
        // have completed.
        withExtendedLifetime(blockBuffer) {}
    }
}
