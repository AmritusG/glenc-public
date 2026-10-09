// SPDX-License-Identifier: MIT
import Foundation
import QuartzCore
#if os(iOS)
import UIKit
#endif

/// Frame clock for DXV playback. Computes the current frame index from
/// elapsed wall-clock time relative to a play-start anchor, so it's
/// drift-correct: pause/resume preserves the frame, scrub sets a new
/// anchor, and small per-frame timing jitter doesn't accumulate.
///
/// Drives via vsync. The display-link source is branched by platform:
/// macOS uses `CVDisplayLink` (CoreVideo, callback fires on a CV-owned
/// high-priority thread; we hop to `DispatchQueue.main`). iOS uses
/// `CADisplayLink` (UIKit, attached to `RunLoop.main` with mode
/// `.common`, so its selector fires on the main thread directly — no
/// hop needed). The drift-correct target-frame math is platform-
/// agnostic and shared between the two branches.
///
/// At each vsync the clock evaluates the target frame; if it changed
/// since the last tick, it fires the callback. For 30fps source on a
/// 60Hz display this means the callback fires every other vsync; for
/// 24fps on 60Hz it fires unevenly (2-3 pattern, judder is inherent to
/// the rate mismatch — we don't try to hide it). On a 120Hz ProMotion
/// iPad, 30fps fires every fourth tick — same logic, finer grain.
///
/// Threading: callbacks fire on the main thread on both platforms.
/// Pause/resume/seek are main-thread methods. State is plain Swift; no
/// locks because we never touch state from anywhere but main.
public final class FrameClock {
    /// Source fps (e.g. 29.97). Drives target frame index calculation.
    public let frameRate: Double
    /// Total frame count. Drives looping/EOF behavior.
    public let totalFrames: Int
    /// Whether to loop at end-of-stream. When true, frame index wraps
    /// modulo totalFrames; when false, clock pauses at last frame.
    public var loops: Bool = true

    /// Called when the target frame index changes. Receives the new
    /// frame index. Always runs on the main thread.
    public var onFrameChange: ((Int) -> Void)?

    /// Stage A audio-master hook. When set and returning a non-nil value,
    /// `tick()` derives the target frame from this audio render position
    /// (seconds) instead of the `CACurrentMediaTime()` wall clock. This
    /// is the SINGLE attach point: the display link still drives the
    /// cadence; only the *time source* is replaced. When unset (HAP, the
    /// no-audio DXV path) the wall-clock path runs byte-for-byte as
    /// before. Always read on the main thread inside `tick()`.
    public var audioTimeSource: (() -> Double?)?

    /// Called from `seek(to:)` with the clamped target frame, so an
    /// audio-master consumer can reposition the audio engine in lockstep.
    /// `stepFrame` routes through `seek`, so it fires here too. nil when
    /// no audio is attached. Runs on the main thread.
    public var onSeek: ((Int) -> Void)?

    /// Item 1 never-prime watchdog. Fired once on the main thread when the
    /// clock is in audio-master mode but `audioTimeSource()` has returned
    /// nil continuously for longer than the prime grace since playback
    /// started — i.e. audio never started/rendered. The consumer falls back
    /// to the wall clock so video never silently freezes (§1).
    public var onAudioUnavailable: (() -> Void)?

    /// Current frame index. Read-only externally; updated internally on
    /// each tick.
    public private(set) var currentFrame: Int = 0

    /// Whether the clock is paused. When paused, vsync ticks are
    /// ignored and currentFrame stays put.
    public private(set) var isPaused: Bool = true

    // Display-link source + anchors. Phase 3b: the display-link type
    // differs by platform (CV on macOS, CA on iOS) but the start /
    // stop / tick contract is identical. On iOS we additionally hold
    // a strong reference to a tiny NSObject proxy (`DisplayLinkProxy`,
    // defined below this class) because CADisplayLink targets a
    // selector on an Obj-C class — FrameClock isn't NSObject, the
    // proxy is.
    #if os(macOS)
    private var displayLink: CVDisplayLink?
    #elseif os(iOS)
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    #endif
    private var startWallTime: CFTimeInterval = 0
    private var startFrame: Int = 0

    // Item 1 never-prime watchdog state (audio-master mode only). Updated
    // on each tick: the timestamp of the last good (non-nil) audio
    // position, and whether the unavailable signal has already fired this
    // play session. Re-armed on play().
    private var lastAudioOKTime: CFTimeInterval = 0
    private var audioWatchdogFired: Bool = false
    /// Grace window after playback starts before a continuously-nil audio
    /// source is declared dead. Long enough that normal priming (a few ms)
    /// never trips it; short enough that a real failure surfaces fast.
    private static let audioPrimeGrace: CFTimeInterval = 0.25

    // Diagnostic counters — printed by stop() to verify the clock fired.
    private var tickCount: Int = 0
    private var frameChangeCount: Int = 0
    /// Cumulative frames *skipped* — i.e. when one tick advanced
    /// currentFrame by more than 1 because main was contended and ticks
    /// arrived in a burst. (advance by 3 = 2 skipped.) Useful for
    /// detecting main-thread saturation.
    private var skippedFrames: Int = 0
    /// Tick-rate window — prints once per second how many ticks fired.
    private var tickWindowStart: CFTimeInterval = 0
    private var tickWindowCount: Int = 0

    public init(frameRate: Double, totalFrames: Int) {
        precondition(frameRate > 0, "frameRate must be positive")
        precondition(totalFrames > 0, "totalFrames must be positive")
        self.frameRate = frameRate
        self.totalFrames = totalFrames
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Start the display-link-driven clock. Frame deliveries begin at
    /// the next vsync. Idempotent.
    public func start() {
        guard displayLink == nil else {
            print("Glance/clock: start() — already running")
            return
        }
        #if os(macOS)
        var link: CVDisplayLink?
        let status = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard status == kCVReturnSuccess, let link = link else {
            print("Glance/clock: CVDisplayLink create FAILED (\(status))")
            return
        }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        let cbStatus = CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, ctx in
            guard let ctx = ctx else { return kCVReturnSuccess }
            let me = Unmanaged<FrameClock>.fromOpaque(ctx).takeUnretainedValue()
            // Hop to main; the SwiftUI/AppKit + GL pipeline expects
            // main-thread callbacks. CVDisplayLink fires on its own
            // high-priority thread.
            DispatchQueue.main.async {
                me.tick()
            }
            return kCVReturnSuccess
        }, opaque)
        if cbStatus != kCVReturnSuccess {
            print("Glance/clock: SetOutputCallback FAILED (\(cbStatus))")
            return
        }
        displayLink = link
        let startStatus = CVDisplayLinkStart(link)
        if startStatus != kCVReturnSuccess {
            print("Glance/clock: Start FAILED (\(startStatus))")
            return
        }
        #elseif os(iOS)
        // CADisplayLink target/selector requires an Obj-C class.
        // The proxy holds a weak ref back to self (no retain cycle —
        // we own the proxy strongly via `displayLinkProxy`). Attaching
        // to `RunLoop.main` with `.common` mode means the selector
        // fires on the main thread, so no DispatchQueue hop is needed
        // (unlike the CV branch above). On 120Hz ProMotion devices
        // CADisplayLink defaults to 60Hz unless `preferredFrameRateRange`
        // is set; for our 30fps-source content evaluating every 60Hz
        // tick is identical to the Mac 60Hz behaviour, so we accept
        // the default rather than asking for higher fidelity we don't
        // need.
        let proxy = DisplayLinkProxy(clock: self)
        let link = CADisplayLink(
            target: proxy,
            selector: #selector(DisplayLinkProxy.displayLinkFired(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLink = link
        #endif
        print("Glance/clock: started — \(totalFrames) frames @ \(frameRate)fps")
    }

    /// Stop the display link and release it. Safe to call multiple times.
    public func stop() {
        if let link = displayLink {
            #if os(macOS)
            CVDisplayLinkStop(link)
            #elseif os(iOS)
            // `invalidate()` both stops firing AND removes from any
            // attached run loops; balanced against `start()`'s
            // `add(to:.main, forMode:.common)`.
            link.invalidate()
            #endif
            displayLink = nil
            #if os(iOS)
            displayLinkProxy = nil
            #endif
            print("Glance/clock: stopped — total ticks=\(tickCount), frame changes=\(frameChangeCount), frames skipped (main contended)=\(skippedFrames)")
        }
    }

    /// Begin (or resume) playback. Anchors wall-clock time to the
    /// current frame so we resume from where we paused, not from where
    /// the clock would have been if it had kept running.
    public func play() {
        if !isPaused { return }
        startWallTime = CACurrentMediaTime()
        startFrame = currentFrame
        isPaused = false
        // Arm the audio never-prime watchdog (Item 1) when in audio-master
        // mode, so a clip whose audio never renders falls back instead of
        // freezing. No effect on the wall-clock path.
        if audioTimeSource != nil {
            lastAudioOKTime = CACurrentMediaTime()
            audioWatchdogFired = false
        }
    }

    /// Pause playback. Frame index sticks at its current value.
    public func pause() {
        isPaused = true
    }

    /// Toggle pause/play.
    public func togglePause() {
        if isPaused { play() } else { pause() }
    }

    /// Seek to a specific frame index. Sets a new anchor so playback
    /// continues from the seek target. Clamped to [0, totalFrames-1].
    public func seek(to frame: Int) {
        let clamped = max(0, min(totalFrames - 1, frame))
        currentFrame = clamped
        // Re-anchor regardless of pause state so play() picks up here.
        startWallTime = CACurrentMediaTime()
        startFrame = clamped
        // Audio-master: reposition the audio engine to match (no-op when
        // no audio is attached). Fire before onFrameChange so audio is
        // already seeking by the time the renderer updates.
        onSeek?(clamped)
        // Fire callback so renderer updates even when paused.
        onFrameChange?(clamped)
    }

    /// Step one frame in the given direction. Implies pause.
    /// internal video-only step; consumers use <Player>.stepFrame(forward:), which also pauses audio.
    func stepFrame(forward: Bool) {
        if !isPaused { pause() }
        let next = currentFrame + (forward ? 1 : -1)
        seek(to: next)
    }

    // MARK: - Internal

    // `fileprivate` (Phase 3b) so the iOS-only `DisplayLinkProxy` below
    // can forward the CADisplayLink selector into the clock's tick
    // logic. The macOS CVDisplayLink callback closure also calls this
    // via an `Unmanaged<FrameClock>` round-trip; same end result.
    fileprivate func tick() {
        tickCount += 1

        // Tick-rate observability: count ticks within a 1-second window
        // and print when full. If display link target is 60Hz/120Hz but
        // we observe much less, main thread is saturated.
        let nowMedia = CACurrentMediaTime()
        if tickWindowStart == 0 { tickWindowStart = nowMedia }
        tickWindowCount += 1
        if nowMedia - tickWindowStart >= 1.0 {
            print(String(format: "Glance/clock: %d ticks/s (display link rate)", tickWindowCount))
            tickWindowStart = nowMedia
            tickWindowCount = 0
        }

        guard !isPaused else { return }

        // Stage A audio-master: when an audio time source is installed,
        // the video frame index follows the audio render position instead
        // of the CACurrentMediaTime wall clock. The display link still
        // drives the cadence — this is the single attach point; we replace
        // the TIME SOURCE, not the vsync trigger. When no source is set
        // (HAP, no-audio DXV) the wall-clock path below runs unchanged.
        if let audioTimeSource = audioTimeSource {
            guard let audioSeconds = audioTimeSource() else {
                // Audio installed but not yet primed (or momentarily
                // unavailable): hold the current frame rather than
                // advancing on the wall clock, so we never desync.
                // Item 1: if this persists past the prime grace since
                // playback started, audio never started/rendered — signal
                // so the consumer can fall back to the wall clock. A frozen
                // video is never acceptable (§1).
                if Self.audioWatchdogTripped(now: nowMedia,
                                             lastAudioOK: lastAudioOKTime,
                                             grace: Self.audioPrimeGrace,
                                             alreadyFired: audioWatchdogFired) {
                    audioWatchdogFired = true
                    onAudioUnavailable?()
                }
                return
            }
            // Healthy audio position — re-arm the watchdog.
            lastAudioOKTime = nowMedia
            audioWatchdogFired = false
            // Item 2: derive the target from the audio position, clamped to
            // the video range so audio and video wrap together even when
            // their loop lengths differ (audio is the master; AudioClock
            // already wrapped `audioSeconds` to its loop length).
            let result = Self.audioMasterTarget(audioSeconds: audioSeconds,
                                                frameRate: frameRate,
                                                totalFrames: totalFrames,
                                                loops: loops)
            if result.reachedEOF { isPaused = true }
            if result.frame != currentFrame {
                let step = result.frame - currentFrame
                if step > 1 { skippedFrames += step - 1 }
                currentFrame = result.frame
                frameChangeCount += 1
                onFrameChange?(result.frame)
            }
            return
        }

        let elapsed = nowMedia - startWallTime
        let advance = Int((elapsed * frameRate).rounded(.down))
        var target = startFrame + advance
        if target >= totalFrames {
            if loops {
                // Re-anchor at the wrap point so we don't accumulate
                // drift across loops. target % totalFrames is the
                // frame-in-loop; we set currentFrame and a new anchor.
                let intoLoop = target % totalFrames
                target = intoLoop
                startFrame = intoLoop
                startWallTime = CACurrentMediaTime() - (Double(intoLoop) / frameRate)
            } else {
                target = totalFrames - 1
                isPaused = true
            }
        }
        if target != currentFrame {
            // Track skipped frames for main-thread saturation diagnosis.
            // Normal step is +1; anything more means ticks arrived late
            // and we're catching up.
            let step = target - currentFrame
            if step > 1 { skippedFrames += step - 1 }
            currentFrame = target
            frameChangeCount += 1
            onFrameChange?(target)
        }
    }

    // MARK: - Audio-master pure helpers (unit-tested in GlancePlaybackTests)

    /// Map an audio-master position (within-audio-loop seconds, already
    /// wrapped by AudioClock) to the video target frame. Clamps to
    /// [0, totalFrames-1]: a longer audio track holds the last video frame
    /// until audio wraps; a shorter one truncates to the audio length; a
    /// matching one spans the full range and wraps when audio wraps.
    /// `reachedEOF` is true only for a non-looping clip that has reached the
    /// last frame (the caller pauses, preserving Stage A EOF behaviour).
    /// Round-to-nearest (MaCrate Phase 7.c lesson): floor leaves video up to
    /// a full frame behind audio at each boundary; rounding centres it.
    static func audioMasterTarget(audioSeconds: Double,
                                  frameRate: Double,
                                  totalFrames: Int,
                                  loops: Bool) -> (frame: Int, reachedEOF: Bool) {
        guard totalFrames > 0 else { return (0, false) }
        var target = Int((audioSeconds * frameRate).rounded())
        var reachedEOF = false
        if target >= totalFrames {
            target = totalFrames - 1
            if !loops { reachedEOF = true }
        }
        if target < 0 { target = 0 }
        return (target, reachedEOF)
    }

    /// Item 1 never-prime watchdog predicate: in audio-master mode, declare
    /// audio unavailable when `audioTimeSource()` has been nil continuously
    /// for longer than `grace` since the last good position (or since play),
    /// and we haven't already fired this session.
    static func audioWatchdogTripped(now: CFTimeInterval,
                                     lastAudioOK: CFTimeInterval,
                                     grace: CFTimeInterval,
                                     alreadyFired: Bool) -> Bool {
        return !alreadyFired && (now - lastAudioOK) > grace
    }
}

#if os(iOS)
/// Phase 3b: iOS-only Obj-C proxy bridging `CADisplayLink`'s
/// target/selector contract to `FrameClock.tick()`. `FrameClock` itself
/// is a plain Swift `final class` — making it an `NSObject` subclass
/// would be a public-API change for existing Mac consumers, so this
/// proxy stays the iOS-side adapter. `clock` is weak; `FrameClock`
/// owns the proxy strongly via its `displayLinkProxy` field, balanced
/// by `stop()` clearing both. No retain cycle.
private final class DisplayLinkProxy: NSObject {
    weak var clock: FrameClock?
    init(clock: FrameClock) {
        self.clock = clock
        super.init()
    }
    @objc func displayLinkFired(_ link: CADisplayLink) {
        clock?.tick()
    }
}
#endif
