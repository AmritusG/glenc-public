// SPDX-License-Identifier: MIT
import Foundation
import QuartzCore
import GlanceCore

/// HAP-family playback engine. Sibling to `DXVPlayer` inside
/// `GlancePlayback`: same architecture (demux-once, `FrameClock`-
/// driven, lock-based dispatch with a drop-intermediates pending
/// slot, per-second stats), different decode output — HAP frames
/// emerge as already-decoded RGBA bytes from
/// `GlanceCore.HAPThumbnail.rgbaOfFrame`, so the renderer side
/// stays a single texture upload regardless of the HAP variant
/// (Hap1 / Hap5 / HapY / HapM / HapA).
///
/// Lifecycle:
///   let player = try HAPPlayer(url: someURL)
///   player.onRGBAFrameDecoded = { frame, rgba, w, h, decodeMs in ... }
///   player.play()
///   ... later ...
///   player.pause() / player.seek(to:) / player.stop()
///
/// Threading model mirrors `DXVPlayer`:
/// - Public API runs on main (caller-side SwiftUI / AppKit binding).
/// - Decode runs on a dedicated serial-style queue gated by a lock-
///   based pending slot so a fast scrub can't pile work behind the
///   currently-in-flight decode.
/// - Decoded-frame and stats callbacks hop back to main before
///   firing.
///
/// History: HAPPlayer was prototyped Crate-local during Phase 6.c
/// because the library was being shaped against DXV3 first; this
/// extraction (Crate Phase 7.d / Glance v0.6.3) brings it
/// alongside `DXVPlayer` so any Glance-family consumer can play
/// HAP without duplicating the engine.
public final class HAPPlayer {

    /// Source URL — kept for diagnostics and file-handle lifetime.
    public let url: URL
    public let index: HAPMovieIndex
    public let clock: FrameClock

    /// Fires on the main thread with `(frameIndex, rgba, width,
    /// height, decodeMs)` when a decode lands. Consumer (typically
    /// a `CAOpenGLLayer` or equivalent) stashes the bytes in a
    /// pending upload slot and calls `setNeedsDisplay()`.
    public var onRGBAFrameDecoded: ((_ frameIndex: Int, _ rgba: [UInt8], _ width: Int, _ height: Int, _ decodeMs: Double) -> Void)?

    /// Fires on the main thread for decode failures. Logged
    /// upstream; doesn't crash the player.
    public var onDecodeError: ((_ frameIndex: Int, _ error: Error) -> Void)?

    /// Per-second decode stats. Same shape as `DXVPlayer.Stats` so
    /// consumers can run the same degradation gate
    /// ("STATS WARNING" if `dropped > 0` or `maxDecodeMs > 25`).
    public var onStats: ((_ stats: Stats) -> Void)?

    public struct Stats {
        public let frameCount: Int
        public let meanDecodeMs: Double
        public let maxDecodeMs: Double
        public let dropped: Int
        public let windowSeconds: Double
        public var summary: String {
            String(format: "%.0f frames in %.1fs — mean=%.2fms max=%.2fms dropped=%d",
                   Double(frameCount), windowSeconds,
                   meanDecodeMs, maxDecodeMs, dropped)
        }
    }

    // MARK: - Audio (Stage B — mirrors DXVPlayer's A2 audio glue)

    // NOTE (tech-debt): this AudioState enum, audioLengthMismatch, the
    // init do/catch, setAudioState, and fallBackToWallClock are a
    // deliberate mirror of DXVPlayer's A2 audio glue. The HEAVY logic is
    // already shared (AudioClock, FrameClock.audioTimeSource/onSeek/
    // onAudioUnavailable, the watchdog + fallback decision); only this
    // thin per-player wiring is duplicated. Extracting it into a shared
    // audio-master component (and migrating DXVPlayer onto it, re-
    // validating DXV) is the clean future cleanup — not done here so
    // DXVPlayer stays exactly as validated.

    /// Stage B audio state (§5) — model data the consumer reads and
    /// surfaces in the UI, NOT a log line. `.playing` when the clip's audio
    /// track loaded and drives the clock; `.none` when there's no audio
    /// track (video plays on the wall clock — never a silent drop, §1);
    /// `.failed` when audio exists but setup/validation failed (video still
    /// plays). Mirror of `DXVPlayer.AudioState`.
    public enum AudioState: Equatable {
        case playing(sampleRate: Double, channels: Int)
        case none(reason: String)
        case failed(reason: String)
    }

    /// Current audio state (§5). `.none`/`.failed` mean video is on the
    /// wall-clock master.
    public private(set) var audioState: AudioState = .none(reason: "uninitialized")

    /// Fired on the main thread whenever `audioState` changes at runtime
    /// (e.g. a play-time / never-prime fallback), so the consumer can update
    /// its visible indicator. NOT fired for the init-time state.
    public var onAudioStateChange: ((AudioState) -> Void)?

    /// True when the audio track and video durations differ by more than one
    /// frame, so the consumer can surface the mismatch. Set in init.
    public private(set) var audioLengthMismatch: Bool = false

    /// Stage D: audio output gain, LINEAR, clamped to [0, 1]. Default 1.0.
    /// Stored as intent and forwarded to the AudioClock when present (a
    /// harmless no-op on a no-audio player; the getter returns the stored
    /// intent). GAIN ONLY — setting level/mute never stops, reschedules, or
    /// re-anchors the audio node, and never moves the master-clock position:
    /// a muted clip stays in perfect video sync, silent not stopped.
    /// Mirror of `DXVPlayer`.
    public var volume: Float {
        get { _volume }
        set {
            _volume = min(1.0, max(0.0, newValue))
            audioClock?.volume = _volume
        }
    }
    /// Mute toggle, SEPARATE from `volume` so unmute restores the prior
    /// level. Default false. Effective node gain = `isMuted ? 0 : volume`.
    public var isMuted: Bool {
        get { _isMuted }
        set {
            _isMuted = newValue
            audioClock?.isMuted = _isMuted
        }
    }
    private var _volume: Float = 1.0
    private var _isMuted: Bool = false

    // MARK: - Internals

    private let fileHandle: FileHandle
    /// Stage B audio engine (audio-master clock). nil when the clip has no
    /// audio track or audio setup failed — video then runs on the FrameClock
    /// wall clock unchanged. Touched only from main.
    private var audioClock: AudioClock?
    private let queue = DispatchQueue(label: "com.amritus.glance.happlayer.decode", qos: .userInteractive)

    private let pendingLock = NSLock()
    private var pendingFrame: Int? = nil
    private var serviceScheduled: Bool = false
    private var inFlight = false

    // Stats window
    private var statsTimes: [Double] = []
    private var statsDropped: Int = 0
    private var lastStatsReport: CFTimeInterval = CACurrentMediaTime()
    private let statsReportInterval: CFTimeInterval = 1.0

    public init(url: URL) throws {
        self.url = url
        self.index = try HAPDemuxer.demux(url: url)
        guard let firstFrame = index.frames.first, firstFrame.size > 0 else {
            throw NSError(domain: "HAPPlayer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no frames in file \(url.lastPathComponent)"])
        }
        self.fileHandle = try FileHandle(forReadingFrom: url)
        self.clock = FrameClock(
            frameRate: index.frameRate > 0 ? index.frameRate : 30.0,
            totalFrames: index.frames.count)
        self.clock.onFrameChange = { [weak self] frameIdx in
            self?.requestDecode(frame: frameIdx)
        }

        // Stage B: attempt audio-master setup, mirroring DXVPlayer. Audio is
        // the canonical clock; video follows it via `clock.audioTimeSource`.
        // NEVER silent-drop (§1): a missing or failed audio track does NOT
        // fail playback — video continues on the wall-clock master and the
        // outcome is recorded as visible `audioState` (§5). The HAP decode/
        // render byte path is untouched; audio is purely additive.
        do {
            let ac = try AudioClock(url: url, loops: clock.loops)
            self.audioClock = ac
            self.audioState = .playing(sampleRate: ac.sampleRate, channels: ac.channelCount)
            // Flag an audio/video length mismatch (> 1 frame) for §5.
            let videoDuration = Double(index.frames.count) / clock.frameRate
            self.audioLengthMismatch = abs(ac.durationSeconds - videoDuration) > (1.0 / clock.frameRate)
            // Single attach point: the clock reads the audio render position.
            self.clock.audioTimeSource = { [weak ac] in ac?.currentSeconds() }
            // Keep audio locked to video on every seek (and frame-step).
            self.clock.onSeek = { [weak self] frame in
                guard let self = self else { return }
                self.audioClock?.seek(toSeconds: Double(frame) / self.clock.frameRate)
            }
            // Never-prime watchdog → fall back to the wall clock.
            self.clock.onAudioUnavailable = { [weak self] in
                self?.fallBackToWallClock(reason: "audio failed to start")
            }
        } catch AudioClockError.noAudioTrack {
            self.audioClock = nil
            self.audioState = .none(reason: "no audio track")
        } catch {
            self.audioClock = nil
            self.audioState = .failed(reason: Self.audioFailureReason(error))
        }
    }

    /// Short, human-readable reason for the degraded-audio model state.
    private static func audioFailureReason(_ error: Error) -> String {
        if let e = error as? AudioClockError { return e.description }
        return error.localizedDescription
    }

    /// Update `audioState` and notify observers (§5). Use for runtime
    /// transitions; init sets `audioState` directly (no observer wired yet).
    private func setAudioState(_ newState: AudioState) {
        audioState = newState
        onAudioStateChange?(newState)
    }

    /// §1/§5: a runtime audio failure must NOT silently freeze video. Revert
    /// the clock to the wall-clock master, tear down the dead engine, re-
    /// anchor to the current frame (no backward jump), and surface the
    /// degraded state. Idempotent. Main-thread only. Mirror of DXVPlayer.
    private func fallBackToWallClock(reason: String) {
        guard audioClock != nil else { return }
        audioClock?.stop()
        audioClock = nil
        clock.audioTimeSource = nil
        clock.onSeek = nil
        clock.onAudioUnavailable = nil
        clock.seek(to: clock.currentFrame)
        setAudioState(.failed(reason: reason))
    }

    deinit {
        clock.stop()
        // §4: explicit audio teardown — never rely on stop() having run.
        audioClock?.stop()
        try? fileHandle.close()
    }

    // MARK: - Public API

    public func play() {
        clock.start()
        // Start audio; if the engine reports it could not start (§1), fall
        // back to the wall clock so video never freezes. `?? true` means
        // "no audio clock → OK".
        let audioStarted = audioClock?.play() ?? true
        clock.play()
        if audioClock != nil && !audioStarted {
            fallBackToWallClock(reason: "audio engine failed to start")
        }
    }

    public func pause() {
        clock.pause()
        audioClock?.pause()
    }

    public func togglePause() {
        // Route through play()/pause() so audio follows the same path.
        if clock.isPaused { play() } else { pause() }
    }

    public func seek(to frame: Int) {
        // Audio is repositioned via clock.onSeek (wired in init).
        clock.seek(to: frame)
    }

    /// Step one frame, holding audio paused. A bare `clock.stepFrame` pauses
    /// only the video clock, so the follow-on seek hits `AudioClock.seek`'s
    /// isPlaying branch and resumes audio. Pausing the player first (audio +
    /// clock) makes the seek re-anchor audio held. Use this, not
    /// `clock.stepFrame`.
    public func stepFrame(forward: Bool) {
        pause()
        let target = max(0, min(totalFrames - 1, currentFrame + (forward ? 1 : -1)))
        seek(to: target)
    }

    /// Set loop state on both the video clock and (in lockstep) the audio
    /// engine, so audio loops/holds with the video.
    public func setLoops(_ on: Bool) {
        clock.loops = on
        audioClock?.setLoops(on)
    }

    public func stop() {
        clock.stop()
        audioClock?.stop()
    }

    public var isPaused: Bool { clock.isPaused }
    public var currentFrame: Int { clock.currentFrame }
    public var totalFrames: Int { index.frames.count }
    public var frameRate: Double { index.frameRate > 0 ? index.frameRate : 30.0 }

    // MARK: - Decode dispatch (lock-based, mirrors DXVPlayer)

    private func requestDecode(frame: Int) {
        pendingLock.lock()
        if pendingFrame != nil {
            // Overwriting a not-yet-decoded request — counts as
            // dropped. During scrub the clock fires faster than
            // decodes complete, so this is expected behaviour.
            statsDropped += 1
        }
        pendingFrame = frame
        let needSchedule = !serviceScheduled
        if needSchedule {
            serviceScheduled = true
        }
        pendingLock.unlock()

        if needSchedule {
            queue.async { [weak self] in
                self?.servicePending()
            }
        }
    }

    private func servicePending() {
        while true {
            pendingLock.lock()
            guard let frame = pendingFrame else {
                serviceScheduled = false
                pendingLock.unlock()
                return
            }
            pendingFrame = nil
            inFlight = true
            pendingLock.unlock()

            decode(frame: frame)

            pendingLock.lock()
            inFlight = false
            pendingLock.unlock()
        }
    }

    private func decode(frame: Int) {
        guard frame >= 0 && frame < index.frames.count else { return }
        let started = CACurrentMediaTime()
        do {
            // `HAPThumbnail.rgbaOfFrame` opens its own file handle.
            // We could instead drive `HAPPacketDecoder.decode` +
            // `HAPHQDecoder.decode*ToRGBA` against `fileHandle`, but
            // the per-frame cost of FileHandle init is small (the
            // kernel page cache holds the file open already after
            // first read) and the rgbaOfFrame entry point handles
            // the per-variant dispatch in one call.
            let result = try HAPThumbnail.rgbaOfFrame(at: frame, in: index, url: url)
            let elapsed = (CACurrentMediaTime() - started) * 1000.0
            recordTiming(elapsed)
            DispatchQueue.main.async { [weak self] in
                self?.onRGBAFrameDecoded?(frame, result.rgba, result.width, result.height, elapsed)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onDecodeError?(frame, error)
            }
        }
    }

    private func recordTiming(_ ms: Double) {
        // Called from `queue`. Stats state is touched only here +
        // emitStats; no other thread reads it concurrently.
        statsTimes.append(ms)
        let now = CACurrentMediaTime()
        if now - lastStatsReport >= statsReportInterval {
            emitStats(now: now)
        }
    }

    private func emitStats(now: CFTimeInterval) {
        let count = statsTimes.count
        guard count > 0 else { return }
        let sum = statsTimes.reduce(0, +)
        let mean = sum / Double(count)
        let max = statsTimes.max() ?? 0
        let windowSec = now - lastStatsReport
        let dropped = statsDropped
        let stats = Stats(
            frameCount: count, meanDecodeMs: mean, maxDecodeMs: max,
            dropped: dropped, windowSeconds: windowSec
        )
        statsTimes.removeAll(keepingCapacity: true)
        statsDropped = 0
        lastStatsReport = now
        DispatchQueue.main.async { [weak self] in
            self?.onStats?(stats)
        }
    }
}
