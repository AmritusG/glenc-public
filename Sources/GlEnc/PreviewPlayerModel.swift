// SPDX-License-Identifier: MIT
import Foundation
import Combine
import CoreGraphics
import AVFoundation
import AppKit
import QuartzCore
import GlanceCore
import GlancePlayback

/// Tiny NSObject that owns a `CADisplayLink` and forwards each vsync to
/// a closure. `CADisplayLink(target:selector:)` needs an `@objc` target;
/// `PreviewPlayerModel` is not an `NSObject`, so the link lives here.
/// The link is added to the main run loop, so `onTick` fires on the
/// main thread (the model reaches its `@MainActor` state via
/// `assumeIsolated`, mirroring `AVPlaybackBackend`'s time observer).
private final class DisplayLinkTicker: NSObject {
    var onTick: (() -> Void)?
    private var link: CADisplayLink?

    func start() {
        guard link == nil, let screen = NSScreen.main else { return }
        let l = screen.displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() { onTick?() }
}

/// Phase 8B-c + v0.9.0-fix — observable model owning the active
/// playback backend. Two backends are supported:
///   - `DXVPlayer` (GlancePlayback) for DXV3 sources. Frames are
///     decoded on a background queue and delivered as DXT/HQ bytes
///     via outbound closures the hosting NSView wires into
///     `DXVRenderer.uploadFrame` / `uploadHQFrame`.
///   - `AVPlaybackBackend` (AVFoundation) for everything else
///     (H.264 / ProRes / MPEG-4 / etc.). The hosting NSView attaches
///     the backend's `AVPlayer` to an `AVPlayerLayer` directly; no
///     GL renderer needed.
///
/// The factory consults `DXVDetector.compressorFourCC` (same source of
/// truth as `SourceFrameReader.makeSourceReader` and
/// `PreviewPosterLoader.loadPoster`) to choose. SwiftUI views observe
/// the same `@Published` state regardless of backend; the hosting view
/// uses `backendKind` to decide which CALayer to show.
@MainActor
final class PreviewPlayerModel: ObservableObject {

    enum PlayState: Equatable {
        case empty       // nothing loaded
        case loading     // load(url:) called, player not yet ready
        case playing
        case paused
        case failed(String)
    }

    @Published private(set) var playState: PlayState = .empty
    @Published private(set) var currentFrame: Int = 0
    @Published private(set) var totalFrames: Int = 0
    @Published private(set) var sourceWidth: Int = 0
    @Published private(set) var sourceHeight: Int = 0
    @Published private(set) var frameRate: Double = 0
    /// Whether playback wraps at end-of-clip or stops. Mirrors
    /// `FrameClock.loops` (DXV) / `AVPlaybackBackend.loops` (AV).
    /// Defaults to true (loop) to match Glance.app's VJ-oriented
    /// behavior.
    @Published var loopEnabled: Bool = true {
        didSet {
            switch backend {
            case .dxv(let p): p.clock.loops = loopEnabled
            case .hap(let p):
                p.clock.loops = loopEnabled
                audioPlayer?.numberOfLoops = loopEnabled ? -1 : 0
            case .av(let b):  b.loops = loopEnabled
            case .none: break
            }
        }
    }

    /// Phase v0.9.0-fix — which backend is currently active. The
    /// hosting view reads this to decide which CALayer to show
    /// (PreviewVideoLayer for DXV, AVPlayerLayer for AV, hapImageLayer
    /// for HAP).
    enum BackendKind {
        case dxv
        case av
        case hap
    }
    @Published private(set) var backendKind: BackendKind = .dxv

    /// Whether the PREVIEWED SOURCE carries an alpha channel. Source-
    /// truth: the selected OUTPUT codec does NOT affect this — it's a
    /// property of the file being previewed. Drives the preview
    /// transparency checkerboard across ALL THREE backends (HAP / DXV /
    /// AV), replacing the earlier HAP-only gate. Set once per `load`:
    ///   - HAP: FourCC (`Hap5`/`HapM`/`HapA` → true; `Hap1`/`HapY` → false)
    ///   - DXV: variant (`dxt5`/`yg10` → true; `dxt1`/`ycg6` → false)
    ///   - AV:  source codec subtype (ProRes 4444 `ap4h`/`ap4x` → true)
    /// Defaults false (nothing loaded / opaque source → no checker).
    @Published private(set) var previewSourceHasAlpha: Bool = false

    /// AVPlayer instance backing `.av` mode. Hosting view installs it
    /// on its AVPlayerLayer. nil when in `.dxv` mode or before a
    /// successful load.
    var avPlayer: AVPlayer? {
        if case .av(let b) = backend { return b.player }
        return nil
    }

    /// Phase 8C-a — in/out frame markers for trim. nil = no trim on
    /// that side. These mirror the corresponding `EncodeJob.inFrame /
    /// outFrame` for the selected row; `PreviewPane` reconciles
    /// changes in both directions via `.onChange` modifiers.
    /// The ScrubBar reads + writes these directly.
    @Published var inFrame: Int? = nil
    @Published var outFrame: Int? = nil

    /// The URL currently loaded, or nil. Used by the hosting view to
    /// decide whether to re-attach when the model changes.
    private(set) var currentURL: URL?

    /// Tagged union of the active backend. PreviewPlayerModel's
    /// public methods dispatch over this; the rest of the codebase
    /// doesn't see it.
    private enum Backend {
        case dxv(DXVPlayer)
        case av(AVPlaybackBackend)
        case hap(HAPPlayer)
    }
    private var backend: Backend?

    /// Fired on main thread when a new DXT1/DXT5 frame is decoded
    /// (DXV backend only). Hosting NSView sets this to wire
    /// `DXVRenderer.uploadFrame`.
    var onDXTFrame: ((DXVRenderer.Variant, Data, Int, Int) -> Void)?

    /// Fired on main thread when a new YCG6/YG10 frame is decoded
    /// (DXV backend only). Hosting NSView sets this to wire
    /// `DXVRenderer.uploadHQFrame`.
    var onHQFrame: ((DXVRenderer.HQFrameData, DXVRenderer.Variant) -> Void)?

    /// Fired on main thread when a new HAP frame is decoded (HAP backend
    /// only). HAPPlayer emits already-decoded straight-alpha RGBA
    /// (`[UInt8]`, R-G-B-A, `width*height*4`); the hosting NSView wraps
    /// it in a CGImage and sets `hapImageLayer.contents`. Distinct from
    /// the DXT/HQ block path because no GL/DXVRenderer is involved.
    var onRGBAFrame: (([UInt8], Int, Int) -> Void)?

    /// Fired on main thread when the alpha-AV pump pulls a new decoded
    /// CVPixelBuffer (ProRes 4444 with alpha only). The hosting NSView
    /// converts it to a CGImage off-main (CIContext, honouring the
    /// buffer's `kCVImageBufferAlphaChannelMode`) and presents on
    /// `cpuImageLayer`. Distinct from `onRGBAFrame` because the source is
    /// a `CVPixelBuffer`, not pre-decoded RGBA. Opaque AV never fires it.
    var onAVPixelBuffer: ((CVPixelBuffer) -> Void)?

    /// `AVPlayerItemVideoOutput` attached to the active AV item ONLY when
    /// the source is genuinely-alpha (ProRes 4444 w/ alpha). nil for
    /// opaque AV (which stays purely on AVPlayerLayer) and all non-AV
    /// backends. Torn down on unload.
    private var avVideoOutput: AVPlayerItemVideoOutput?
    /// Display-link pump that pulls CVPixelBuffers from `avVideoOutput`
    /// at vsync. Reuses the same `DisplayLinkTicker` shape used by the
    /// HAP audio-master clock (NSScreen.displayLink → main-thread tick).
    private let avAlphaTicker = DisplayLinkTicker()

    /// One-shot guard so the HAP arm logs its resolved surface format
    /// exactly once (first decoded HAP frame) instead of per-frame.
    private var loggedHAPDiag = false

    // MARK: - HAP audio-master playback (HAP arm only)
    //
    // When a HAP file carries a decodable audio track, AVAudioPlayer
    // becomes the canonical clock: we do NOT start HAPPlayer's
    // FrameClock display link (`HAPPlayer.play()`); instead a
    // GlEnc-owned CADisplayLink reads `audioPlayer.currentTime` each
    // vsync, derives the target video frame, and drives
    // `HAPPlayer.seek(to:)` (which emits a decoded frame independent of
    // the clock tick). Video frame index becomes a pure function of
    // audio time → no A/V drift. When there is no audio track,
    // `audioMaster` stays false and the existing clock-master path runs
    // (silent, unchanged). Audio is HAP-only — never wired for DXV/AV.

    /// AVAudioPlayer when the active HAP has a decodable audio track;
    /// nil for video-only HAP (clock-master, silent).
    private var audioPlayer: AVAudioPlayer?
    /// True when `audioPlayer` drives the clock (has audio). False →
    /// clock-master fallback identical to pre-audio behavior.
    /// Read-only outside the model (tests assert on it).
    private(set) var audioMaster = false
    /// Vsync source that maps audio time → video frame in audio-master.
    private let audioTicker = DisplayLinkTicker()
    /// Last frame the tick seeked to, so we only seek on change.
    private var lastAudioTargetFrame = -1

    /// Compressor FourCCs that route to DXVPlayer. Matches the set in
    /// `SourceFrameReader.makeSourceReader` + `PreviewPosterLoader`.
    private static let dxvFourCCs: Set<String> = [
        "DXT1", "DXT5", "YCG6", "YG10", "DXDI", "DXD3",
    ]

    /// Whether a HAP-family compressor FourCC carries alpha. `Hap5`
    /// (RGBA DXT5), `HapM` (HapY+HapA wrapper), and `HapA` (alpha-only)
    /// carry alpha; `Hap1` (RGB DXT1) and `HapY` (scaled-YCoCg, opaque)
    /// do not. Pure; unit-tested.
    static func hapFourCCHasAlpha(_ fourCC: String) -> Bool {
        switch fourCC {
        case "Hap5", "HapM", "HapA": return true
        default:                     return false   // Hap1, HapY opaque
        }
    }

    /// Whether a DXV3 texture variant carries alpha. `dxt5` and `yg10`
    /// are the alpha variants; `dxt1` and `ycg6` are opaque. Pure;
    /// unit-tested.
    static func dxvVariantHasAlpha(_ variant: DXVVariant) -> Bool {
        switch variant {
        case .dxt5, .yg10: return true
        case .dxt1, .ycg6: return false
        }
    }

    // MARK: - Lifecycle

    func load(url: URL) {
        // Tear down any previous player before swapping URLs so
        // background tickers don't keep firing against a stale model.
        unload()
        currentURL = url
        playState = .loading
        // Source-alpha is recomputed per load. Reset to false up front;
        // each backend arm below sets the real value (AV does it async
        // once the codec subtype probe resolves).
        previewSourceHasAlpha = false

        // Routing — same source of truth as SourceFrameReader +
        // PreviewPosterLoader. HAP is checked FIRST and routed to
        // HAPPlayer; it must NOT join the dxvFourCCs gate (that path
        // feeds DXVPlayer, which can't decode HAP). Then DXV3 family →
        // DXVPlayer; everything else → AVPlaybackBackend.
        if let hapCC = HAPDetector.compressorFourCCIfHAP(at: url) {
            previewSourceHasAlpha = Self.hapFourCCHasAlpha(hapCC)
            loadHAP(url: url)
            return
        }
        let cc = DXVDetector.compressorFourCC(at: url)
        let isDXV = (cc.map { Self.dxvFourCCs.contains($0) } ?? false)

        if isDXV {
            loadDXV(url: url)
        } else {
            loadAV(url: url)
        }
    }

    private func loadDXV(url: URL) {
        do {
            let p = try DXVPlayer(url: url)
            try wirePlayer(p)
            previewSourceHasAlpha = Self.dxvVariantHasAlpha(p.index.variant)
            backend = .dxv(p)
            backendKind = .dxv
            totalFrames = p.totalFrames
            frameRate = p.frameRate
            sourceWidth = p.index.width
            sourceHeight = p.index.height
            currentFrame = 0
            // Phase 8B-d: push current loop preference onto the freshly-
            // built clock so the user's toggle state persists across
            // file loads.
            p.clock.loops = loopEnabled
            // Phase 8B-c: auto-play on load.
            p.play()
            playState = .playing
        } catch {
            playState = .failed("Couldn't load: \(error.localizedDescription)")
            totalFrames = 0
            sourceWidth = 0
            sourceHeight = 0
        }
    }

    /// HAP backend (Hap1/Hap5/HapY/HapM). Mirrors `loadDXV` but builds a
    /// `HAPPlayer`, which emits decoded RGBA rather than DXT/HQ blocks.
    private func loadHAP(url: URL) {
        do {
            let p = try HAPPlayer(url: url)
            wireHAPPlayer(p)
            backend = .hap(p)
            backendKind = .hap
            totalFrames = p.totalFrames
            frameRate = p.frameRate
            sourceWidth = p.index.width
            sourceHeight = p.index.height
            currentFrame = 0
            p.clock.loops = loopEnabled
            // Audio-master setup (HAP-only): if the file has a decodable
            // audio track, AVAudioPlayer becomes the clock; otherwise
            // silent clock-master fallback (existing behavior).
            setupHAPAudio(url: url)
            // Emit frame 0 immediately (seek drives a decode independent
            // of the clock), then start playback via the shared play()
            // which branches audio-master vs clock-master.
            p.seek(to: 0)
            play()
        } catch {
            playState = .failed("Couldn't load: \(error.localizedDescription)")
            totalFrames = 0
            sourceWidth = 0
            sourceHeight = 0
        }
    }

    private func loadAV(url: URL) {
        // AVPlaybackBackend.init is async (asset load is async); kick
        // it off in a MainActor-bound Task and finish setup when the
        // asset's tracks have loaded. Explicit @MainActor annotation
        // so the captured self.* property writes stay on-actor under
        // strict concurrency.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let b = try await AVPlaybackBackend(url: url)
                // Guard against the URL changing mid-load (user
                // selected a different row while we were awaiting).
                guard self.currentURL == url else {
                    b.stop()
                    return
                }
                b.loops = self.loopEnabled
                b.onCurrentFrameChanged = { [weak self] frame in
                    guard let self else { return }
                    self.currentFrame = frame
                    self.enforceTrimBoundaryIfPlaying()
                }
                self.backend = .av(b)
                self.backendKind = .av
                self.totalFrames = b.totalFrames
                self.frameRate = b.frameRate
                self.sourceWidth = b.sourceWidth
                self.sourceHeight = b.sourceHeight
                self.currentFrame = 0
                // Source-alpha probe for AV sources (ProRes 4444 →
                // alpha). Async; the codec-subtype read isn't available
                // synchronously. PreviewPlayerModel is @MainActor so the
                // continuation resumes on-actor; guard the URL hasn't
                // changed mid-probe before publishing.
                let alpha = (await EncodeJob.probeSourceAlpha(url)) ?? false
                guard self.currentURL == url else { return }
                self.previewSourceHasAlpha = alpha
                // Genuinely-alpha AV (ProRes 4444 w/ alpha) → attach a
                // video output + display-link pump so the checkerboard
                // reads through. Opaque AV skips this entirely and stays
                // on AVPlayerLayer (Step 4).
                if alpha {
                    self.setupAlphaAVOutput(item: b.playerItem)
                }
                b.play()
                self.playState = .playing
            } catch {
                guard self.currentURL == url else { return }
                self.playState = .failed("Couldn't load: \(error.localizedDescription)")
                self.totalFrames = 0
                self.sourceWidth = 0
                self.sourceHeight = 0
            }
        }
    }

    // MARK: - Alpha-AV video-output pump (ProRes 4444 + alpha only)

    /// Attach a 32BGRA `AVPlayerItemVideoOutput` to the alpha-AV item and
    /// start the display-link pump. Called only when the source carries
    /// a real alpha channel. Tears down any prior output first (defensive
    /// — `load()` already calls `unload()`).
    private func setupAlphaAVOutput(item: AVPlayerItem) {
        teardownAlphaAVOutput(removingFrom: nil)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        avVideoOutput = output
        avAlphaTicker.onTick = { [weak self] in self?.pullAVPixelBuffer() }
        avAlphaTicker.start()
    }

    /// Vsync tick: map host time → item time, and if a fresh buffer is
    /// available, copy it and hand it to the NSView's off-main converter.
    /// `copyPixelBuffer` just hands over the already-decoded buffer
    /// (cheap on main); the heavy CIContext conversion happens off-main.
    private func pullAVPixelBuffer() {
        guard let output = avVideoOutput else { return }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pb = output.copyPixelBuffer(forItemTime: itemTime,
                                              itemTimeForDisplay: nil)
        else { return }
        onAVPixelBuffer?(pb)
    }

    /// Stop the pump and detach the video output. `removingFrom` is the
    /// item to remove the output from; when nil, resolves it from the
    /// current `.av` backend (so unload can pass its item explicitly
    /// before `backend` is cleared).
    private func teardownAlphaAVOutput(removingFrom item: AVPlayerItem?) {
        avAlphaTicker.stop()
        avAlphaTicker.onTick = nil
        if let output = avVideoOutput {
            let target: AVPlayerItem?
            if let item { target = item }
            else if case .av(let b)? = backend { target = b.playerItem }
            else { target = nil }
            target?.remove(output)
            avVideoOutput = nil
        }
    }

    func play() {
        guard backend != nil else { return }
        // Phase 8C-a-fix — trim is the playable region. If the user
        // presses play with the playhead outside [in, out], snap into
        // the trim window before starting playback so the user sees
        // the trim region from the start.
        snapPlayheadIntoTrimIfNeeded()
        switch backend {
        case .dxv(let p): p.play(); playState = p.isPaused ? .paused : .playing
        case .hap(let p):
            if audioMaster, let ap = audioPlayer {
                // Audio-master: AVAudioPlayer is the clock. Do NOT call
                // p.play() (that starts the FrameClock display link and
                // would double-drive). Align audio to the playhead,
                // start it, and arm the vsync tick that derives frames.
                ap.currentTime = Double(currentFrame) / p.frameRate
                ap.play()
                startAudioTick()
                playState = .playing
            } else {
                p.play(); playState = p.isPaused ? .paused : .playing
            }
        case .av(let b):  b.play(); playState = b.isPaused ? .paused : .playing
        case .none: break
        }
    }

    func pause() {
        switch backend {
        case .dxv(let p): p.pause(); playState = .paused
        case .hap(let p):
            if audioMaster, let ap = audioPlayer {
                ap.pause(); stopAudioTick(); playState = .paused
            } else {
                p.pause(); playState = .paused
            }
        case .av(let b):  b.pause(); playState = .paused
        case .none: break
        }
    }

    func togglePause() {
        guard backend != nil else { return }
        let wasPaused: Bool
        switch backend {
        case .dxv(let p): wasPaused = p.isPaused
        case .hap(let p): wasPaused = audioMaster ? !(audioPlayer?.isPlaying ?? false) : p.isPaused
        case .av(let b):  wasPaused = b.isPaused
        case .none: return
        }
        // Pre-snap before un-pausing (paused→playing transition).
        if wasPaused { snapPlayheadIntoTrimIfNeeded() }
        switch backend {
        case .dxv(let p): p.togglePause(); playState = p.isPaused ? .paused : .playing
        // Route HAP through play()/pause() so the audio-master and
        // clock-master branches are handled in one place.
        case .hap: if wasPaused { play() } else { pause() }
        case .av(let b):  b.togglePause(); playState = b.isPaused ? .paused : .playing
        case .none: break
        }
    }

    /// If trim is active and the current playhead is outside the
    /// `[inFrame, outFrame]` window, seek to `inFrame`. No-op when
    /// trim is inactive or the playhead is already inside the
    /// window. Called by `play()` and `togglePause()` immediately
    /// before un-pausing.
    private func snapPlayheadIntoTrimIfNeeded() {
        let inF = inFrame
        let outF = outFrame
        // Trim inactive → unrestricted playback.
        if inF == nil && outF == nil { return }
        let lo = inF ?? 0
        let hi = outF ?? (totalFrames - 1)
        if currentFrame < lo || currentFrame > hi {
            seek(to: lo)
        }
    }

    /// Phase 8C-a-fix — enforce trim window during playback. Fired
    /// from the player's frame-decoded callback after `currentFrame`
    /// has been updated. Only acts when actively playing; manual
    /// scrubbing (which pauses playback) is unrestricted per the
    /// locked decisions.
    ///
    /// Semantics:
    ///   - Trim inactive: no-op (FrameClock's own loop / pause-at-end
    ///     handles the full-clip case).
    ///   - Playing past outFrame:
    ///       loopEnabled → wrap to inFrame (loop within trim).
    ///       loopEnabled off → pause at outFrame.
    ///   - Playing before inFrame (rare — only if user scrubbed
    ///     backward + released while playing): wrap to inFrame.
    private func enforceTrimBoundaryIfPlaying() {
        guard playState == .playing else { return }
        let inF = inFrame
        let outF = outFrame
        if inF == nil && outF == nil { return }
        let lo = inF ?? 0
        let hi = outF ?? (totalFrames - 1)
        if currentFrame > hi {
            if loopEnabled {
                seek(to: lo)
            } else {
                seek(to: hi)
                pause()
            }
        } else if currentFrame < lo {
            // Below in. Treat as a loop-wrap (rare scrub-while-playing
            // edge case); jump to in and keep playing.
            seek(to: lo)
        }
    }

    func seek(to frame: Int) {
        let clamped = max(0, min(totalFrames - 1, frame))
        switch backend {
        case .dxv(let p): p.seek(to: frame)
        case .hap(let p):
            p.seek(to: frame)
            if audioMaster, let ap = audioPlayer {
                // Keep audio aligned to the scrub target, and prime the
                // tick's change-detector so it doesn't immediately undo
                // this seek on the next vsync.
                ap.currentTime = Double(clamped) / p.frameRate
                lastAudioTargetFrame = clamped
            }
        case .av(let b):  b.seek(to: frame)
        case .none: break
        }
        currentFrame = clamped
    }

    /// Step one or more frames in either direction. Implies pause —
    /// matches Glance.app's `,`/`.` behavior and the user expectation
    /// that single-stepping is a "scrutinize this frame" action.
    /// Bounds-clamped via `seek(to:)`.
    func step(by delta: Int) {
        guard backend != nil else { return }
        pause()
        seek(to: currentFrame + delta)
    }

    // MARK: - Trim (Phase 8C-a)

    /// Set the in-point at the current playhead. If the resulting
    /// in > out, snap out forward to match (preserves the invariant
    /// in ≤ out without surprising the user). No-op when no player.
    func setInAtCurrentFrame() {
        guard backend != nil else { return }
        let cf = currentFrame
        inFrame = cf
        if let out = outFrame, out < cf {
            outFrame = cf
        }
    }

    /// Set the out-point at the current playhead. Symmetric to
    /// `setInAtCurrentFrame`.
    func setOutAtCurrentFrame() {
        guard backend != nil else { return }
        let cf = currentFrame
        outFrame = cf
        if let inF = inFrame, inF > cf {
            inFrame = cf
        }
    }

    /// Drop both trim points. The next encode will run the full clip.
    func clearTrim() {
        inFrame = nil
        outFrame = nil
    }

    func unload() {
        switch backend {
        case .dxv(let p):
            p.stop()
            p.onFrameDecoded = nil
            p.onHQFrameDecoded = nil
            p.onDecodeError = nil
        case .hap(let p):
            stopAudioTick()
            audioPlayer?.stop()
            audioPlayer = nil
            audioMaster = false
            lastAudioTargetFrame = -1
            p.stop()
            p.onRGBAFrameDecoded = nil
            p.onDecodeError = nil
        case .av(let b):
            b.onCurrentFrameChanged = nil
            // Tear down the alpha-AV pump (no-op for opaque AV — never
            // set up). Remove from this item explicitly while we still
            // hold it, before `backend` is cleared below.
            teardownAlphaAVOutput(removingFrom: b.playerItem)
            b.stop()
        case .none:
            break
        }
        backend = nil
        backendKind = .dxv
        previewSourceHasAlpha = false
        currentURL = nil
        playState = .empty
        currentFrame = 0
        totalFrames = 0
        sourceWidth = 0
        sourceHeight = 0
        frameRate = 0
        // Phase 4.1c — DO NOT reset trim here. `unload()` runs during the
        // `.task(id: loadKey)` reload that fires on re-selecting a clip;
        // nil-ing the model's trim propagates back to the (now-selected)
        // job via PreviewPane's `model.inFrame` onChange → syncModelTrimToJob,
        // wiping the job's saved trim. Trim is per-clip state owned by the
        // EncodeJob; PreviewPane sets the model's trim from the selected
        // job on every selection (syncJobTrimToModel), which already
        // prevents stale markers without a destructive reset here.
    }

    // MARK: - Internal

    /// Wire the player's decode callbacks → model state + outbound
    /// hooks. Routes by `index.variant` to pick DXT vs HQ side.
    private func wirePlayer(_ p: DXVPlayer) throws {
        let w = p.index.width
        let h = p.index.height
        let variant: DXVRenderer.Variant
        switch p.index.variant {
        case .dxt1: variant = .dxt1
        case .dxt5: variant = .dxt5
        case .ycg6: variant = .ycg6
        case .yg10: variant = .yg10
        }

        p.onFrameDecoded = { [weak self] idx, dxtBytes, _ in
            guard let self else { return }
            self.currentFrame = idx
            self.onDXTFrame?(variant, dxtBytes, w, h)
            self.enforceTrimBoundaryIfPlaying()
        }
        p.onHQFrameDecoded = { [weak self] idx, hqFrame, _ in
            guard let self else { return }
            self.currentFrame = idx
            self.onHQFrame?(hqFrame, variant)
            self.enforceTrimBoundaryIfPlaying()
        }
        p.onDecodeError = { idx, err in
            print("[GlEnc/preview] decode error frame \(idx): \(err)")
        }
    }

    /// Wire the HAP player's RGBA callback → model state + the outbound
    /// `onRGBAFrame` hook. HAPPlayer already decodes every variant
    /// (Hap1/Hap5/HapY/HapM) to straight-alpha RGBA, so there is a
    /// single frame path regardless of variant.
    private func wireHAPPlayer(_ p: HAPPlayer) {
        let variant = p.index.variant
        p.onRGBAFrameDecoded = { [weak self] idx, rgba, w, h, _ in
            guard let self else { return }
            if !self.loggedHAPDiag {
                self.loggedHAPDiag = true
                FileHandle.standardError.write(Data(
                    ("[GlEnc/hap] first RGBA frame: variant=\(variant) " +
                     "backendKind=hap display=\(w)x\(h) " +
                     "bytesPerRow=\(w * 4) rgba.count=\(rgba.count) " +
                     "(expected \(w * h * 4))\n").utf8))
            }
            self.currentFrame = idx
            self.onRGBAFrame?(rgba, w, h)
            self.enforceTrimBoundaryIfPlaying()
        }
        p.onDecodeError = { idx, err in
            print("[GlEnc/preview] HAP decode error frame \(idx): \(err)")
        }
    }

    // MARK: - HAP audio-master internals

    /// Attempt to open the HAP file's audio track. On success (a
    /// decodable track with non-zero duration), `audioMaster` becomes
    /// true and `audioPlayer` is the canonical clock. On any failure
    /// (no audio track, AVAudioPlayer throws), `audioMaster` stays false
    /// → silent clock-master playback, behavior unchanged. Audio is
    /// HAP-only; this is never called for the DXV or AV arms.
    private func setupHAPAudio(url: URL) {
        // Tear down any prior audio first (defensive; unload() already
        // does this on URL swap).
        stopAudioTick()
        audioPlayer?.stop()
        audioPlayer = nil
        audioMaster = false
        lastAudioTargetFrame = -1

        guard let ap = try? AVAudioPlayer(contentsOf: url), ap.duration > 0 else {
            return
        }
        ap.prepareToPlay()
        ap.numberOfLoops = loopEnabled ? -1 : 0
        audioPlayer = ap
        audioMaster = true
    }

    private func startAudioTick() {
        audioTicker.onTick = { [weak self] in
            // CADisplayLink added to .main fires on the main thread; the
            // model is @MainActor, so assumeIsolated is valid here
            // (same pattern as AVPlaybackBackend's time observer).
            MainActor.assumeIsolated { self?.audioTickFired() }
        }
        audioTicker.start()
    }

    private func stopAudioTick() {
        audioTicker.stop()
        audioTicker.onTick = nil
    }

    /// One vsync of the audio-master loop: derive the target video frame
    /// from audio time and seek to it (only on change). Handles the
    /// no-loop end-of-clip by pausing; looping audio (numberOfLoops=-1)
    /// wraps `currentTime` so the next tick naturally seeks back to ~0.
    private func audioTickFired() {
        guard audioMaster, let ap = audioPlayer, case .hap(let p)? = backend else { return }
        let fps = p.frameRate
        guard fps > 0 else { return }

        // No-loop end-of-clip: audio reached its end. Pin the last
        // frame, stop audio + tick, and pause.
        if !loopEnabled && ap.currentTime >= ap.duration - (0.5 / fps) {
            let last = max(0, totalFrames - 1)
            if currentFrame != last {
                p.seek(to: last)
                currentFrame = last
            }
            lastAudioTargetFrame = last
            ap.pause()
            stopAudioTick()
            playState = .paused
            return
        }

        let target = max(0, min(totalFrames - 1, Int((ap.currentTime * fps).rounded())))
        if target != lastAudioTargetFrame {
            lastAudioTargetFrame = target
            p.seek(to: target)   // emits a decoded frame → onRGBAFrame
            currentFrame = target
        }
    }
}
