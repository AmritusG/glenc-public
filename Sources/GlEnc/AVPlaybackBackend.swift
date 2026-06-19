// SPDX-License-Identifier: MIT
import Foundation
import AVFoundation

/// Phase v0.9.0-fix — AVPlayer-backed playback for non-DXV3 sources
/// (H.264 / ProRes / MPEG-4 / etc.). Sibling to GlancePlayback's
/// DXVPlayer; same operation surface (play / pause / seek / step / loop
/// + currentFrame / totalFrames / frameRate). PreviewPlayerModel
/// chooses between the two at `load(url:)` based on the file's
/// compressor FourCC.
///
/// Frame indexing is computed from playback time × frame rate. AVPlayer
/// doesn't natively expose a frame counter, so we round
/// `currentTime / frameDuration` and round-trip frame-index seeks
/// through CMTime. For 30 fps sources at ±0.5 frame tolerance this is
/// accurate to the nearest displayed frame.
///
/// Loop behavior matches DXVPlayer's FrameClock contract: a
/// notification observer on `AVPlayerItemDidPlayToEndTime` seeks back
/// to in-point (or 0) when `loops == true`, pauses otherwise.
@MainActor
final class AVPlaybackBackend {

    // MARK: - Public surface (mirrors DXVPlayer)

    let player: AVPlayer
    let totalFrames: Int
    let frameRate: Double
    let sourceWidth: Int
    let sourceHeight: Int

    /// Called on the main thread whenever the time-observer fires —
    /// PreviewPlayerModel uses this to update its `currentFrame`
    /// @Published and enforce trim boundaries.
    var onCurrentFrameChanged: ((Int) -> Void)?

    /// True when the player has been paused via `pause()` or has
    /// reached EOF with `loops == false`.
    var isPaused: Bool { player.timeControlStatus != .playing }

    /// Mirrors `DXVPlayer.clock.loops`. When true, EOF wraps back to
    /// frame 0 (or the trim in-point if PreviewPlayerModel reseeks
    /// before resuming). Toggling at runtime takes effect at next EOF.
    var loops: Bool = true

    /// Read-only seam (alpha-AV preview only): the underlying
    /// `AVPlayerItem`, so an `AVPlayerItemVideoOutput` can attach to pull
    /// straight/premult CVPixelBuffers for the checkerboard route. Does
    /// not affect opaque AV playback, which keeps using `player` +
    /// AVPlayerLayer unchanged.
    var playerItem: AVPlayerItem { item }

    // MARK: - Internals

    private let item: AVPlayerItem
    private var timeObserverToken: Any?
    private var endTimeObserver: NSObjectProtocol?
    private var lastReportedFrame: Int = -1

    // MARK: - Init

    init(url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else {
            throw AVPlaybackError.noVideoTrack
        }
        let size = try await track.load(.naturalSize)
        let nominalFPS = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)

        let fps = Double(nominalFPS)
        let durSec = CMTimeGetSeconds(duration)
        guard fps > 0, durSec > 0, durSec.isFinite,
              size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite else {
            throw AVPlaybackError.unsupportedTrack(fps: fps, durationSec: durSec)
        }

        self.frameRate = fps
        self.sourceWidth = Int(size.width.rounded())
        self.sourceHeight = Int(size.height.rounded())
        self.totalFrames = max(1, Int((durSec * fps).rounded()))

        let item = AVPlayerItem(asset: asset)
        // High tolerance on the player item is set per-seek below.
        self.item = item
        self.player = AVPlayer(playerItem: item)
        self.player.actionAtItemEnd = .pause  // we drive loop via observer

        installTimeObserver()
        installEndObserver()
    }

    deinit {
        // NB: cannot touch self.player here under @MainActor — Swift's
        // strict isolation forbids it. We rely on PreviewPlayerModel
        // calling `stop()` explicitly before dropping the backend.
    }

    // MARK: - Transport

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func togglePause() {
        if isPaused { play() } else { pause() }
    }

    /// Seek to the given frame index. Tight tolerance (1 / (2 × fps))
    /// so the displayed image lands on the requested frame rather than
    /// the nearest keyframe — VideoToolbox handles the decode-back-to-
    /// keyframe walk internally.
    func seek(to frame: Int) {
        let clamped = max(0, min(totalFrames - 1, frame))
        let time = cmTime(forFrame: clamped)
        let tol = CMTime(seconds: 1.0 / (frameRate * 2.0), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tol, toleranceAfter: tol) { _ in }
    }

    func stop() {
        player.pause()
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let obs = endTimeObserver {
            NotificationCenter.default.removeObserver(obs)
            endTimeObserver = nil
        }
    }

    // MARK: - Helpers

    private func cmTime(forFrame frame: Int) -> CMTime {
        CMTime(seconds: Double(frame) / frameRate, preferredTimescale: 600)
    }

    /// Periodic observer at ~half-a-frame cadence. Fires on the main
    /// queue (model is @MainActor). De-dupes by `lastReportedFrame`
    /// so SwiftUI doesn't churn on sub-frame ticks.
    private func installTimeObserver() {
        let interval = CMTime(
            seconds: 1.0 / (frameRate * 2.0),
            preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            // queue: .main means we're on the main thread; the
            // closure type is @Sendable, so reach the @MainActor
            // properties via assumeIsolated.
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = CMTimeGetSeconds(time)
                guard t.isFinite, t >= 0 else { return }
                let frame = Int((t * self.frameRate).rounded())
                let clamped = max(0, min(self.totalFrames - 1, frame))
                if clamped != self.lastReportedFrame {
                    self.lastReportedFrame = clamped
                    self.onCurrentFrameChanged?(clamped)
                }
            }
        }
    }

    /// EOF handler — loop or pause per `loops`. PreviewPlayerModel's
    /// `enforceTrimBoundaryIfPlaying` handles trim-window EOF
    /// (out-point < totalFrames). This observer covers the natural
    /// end-of-clip case.
    private func installEndObserver() {
        endTimeObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                if self.loops {
                    self.seek(to: 0)
                    self.player.play()
                } else {
                    // actionAtItemEnd = .pause already paused; nothing
                    // more to do.
                }
            }
        }
    }
}

enum AVPlaybackError: Error, CustomStringConvertible {
    case noVideoTrack
    case unsupportedTrack(fps: Double, durationSec: Double)

    var description: String {
        switch self {
        case .noVideoTrack:
            return "no video track"
        case .unsupportedTrack(let fps, let dur):
            return "unsupported track (fps=\(fps), duration=\(dur)s)"
        }
    }
}
