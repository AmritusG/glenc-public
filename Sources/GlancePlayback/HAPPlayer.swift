// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
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

    // MARK: - Internals

    private let fileHandle: FileHandle
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
    }

    deinit {
        clock.stop()
        try? fileHandle.close()
    }

    // MARK: - Public API

    public func play() {
        clock.start()
        clock.play()
    }

    public func pause() { clock.pause() }
    public func togglePause() { clock.togglePause() }
    public func seek(to frame: Int) { clock.seek(to: frame) }
    public func stop() { clock.stop() }

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
