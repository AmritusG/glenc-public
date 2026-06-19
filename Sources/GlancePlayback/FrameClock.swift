// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation
import QuartzCore

/// Frame clock for DXV playback. Computes the current frame index from
/// elapsed wall-clock time relative to a play-start anchor, so it's
/// drift-correct: pause/resume preserves the frame, scrub sets a new
/// anchor, and small per-frame timing jitter doesn't accumulate.
///
/// Drives via CADisplayLink (vsync). At each vsync the clock evaluates
/// the target frame; if it changed since the last tick, it fires the
/// callback. For 30fps source on a 60Hz display this means the callback
/// fires every other vsync; for 24fps on 60Hz it fires unevenly (2-3
/// pattern, judder is inherent to the rate mismatch — we don't try to
/// hide it).
///
/// Threading: callbacks fire on the main thread (CADisplayLink default).
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

    /// Current frame index. Read-only externally; updated internally on
    /// each tick.
    public private(set) var currentFrame: Int = 0

    /// Whether the clock is paused. When paused, vsync ticks are
    /// ignored and currentFrame stays put.
    public private(set) var isPaused: Bool = true

    // CADisplayLink and anchors.
    private var displayLink: CVDisplayLink?
    private var startWallTime: CFTimeInterval = 0
    private var startFrame: Int = 0

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
        print("Glance/clock: started — \(totalFrames) frames @ \(frameRate)fps")
    }

    /// Stop the display link and release it. Safe to call multiple times.
    public func stop() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
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
        // Fire callback so renderer updates even when paused.
        onFrameChange?(clamped)
    }

    /// Step one frame in the given direction. Implies pause.
    public func stepFrame(forward: Bool) {
        if !isPaused { pause() }
        let next = currentFrame + (forward ? 1 : -1)
        seek(to: next)
    }

    // MARK: - Internal

    private func tick() {
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
}
