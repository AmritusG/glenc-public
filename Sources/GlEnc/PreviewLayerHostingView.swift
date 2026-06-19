// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation
import CoreImage
import SwiftUI
import GlanceCore
import GlancePlayback

/// AppKit `NSView` hosting two CALayer playback paths and switching
/// between them based on the active backend in `PreviewPlayerModel`:
///   - `PreviewVideoLayer` (CAOpenGLLayer + `DXVRenderer`) for DXV3
///     sources (DXT1/DXT5/YCG6/YG10).
///   - `AVPlayerLayer` for everything else (H.264 / ProRes / MPEG-4 /
///     etc.) via `AVPlaybackBackend.player`.
///
/// The view's backing layer is a vanilla `CALayer` container; both
/// playback layers are added as sublayers and the inactive one is
/// hidden. This avoids the swap-backing-layer-mid-life hazard.
///
/// Phase v0.9.0-fix introduced the AVPlayer branch; the DXV branch is
/// unchanged from Phase 8B-c.
final class PreviewLayerHostingNSView: NSView {

    /// The model whose frames feed this layer. Setter rewires the
    /// callbacks; clearing (to nil) detaches them so the previous
    /// model can't post into a dangling view.
    weak var model: PreviewPlayerModel? {
        didSet {
            oldValue?.onDXTFrame = nil
            oldValue?.onHQFrame = nil
            oldValue?.onRGBAFrame = nil
            oldValue?.onAVPixelBuffer = nil
            wireModel()
        }
    }

    /// HAP-preview checkerboard extent (from AppSettings, pushed by the
    /// representable). `.fillViewport` = checker over the whole preview
    /// (default); `.behindVideoOnly` = confined to the fitted video rect.
    /// Re-frames the checker live on change.
    var checkerboardScope: AppSettings.CheckerboardScope = .fillViewport {
        didSet { if oldValue != checkerboardScope { layoutSublayers() } }
    }

    private let containerLayer = CALayer()
    private let videoLayer = PreviewVideoLayer()
    private let avPlayerLayer = AVPlayerLayer()
    /// Plain CALayer that displays CPU-decoded frames as `contents`
    /// CGImages — shared by the HAP arm, alpha DXV (DXT5/YG10), AND alpha
    /// AV (ProRes 4444). HAPPlayer emits decoded RGBA directly; alpha DXV
    /// is CPU-decoded per frame via `CPURender`; alpha AV via Core Image
    /// from the video-output pump (the opaque DXV/AV paths stay on the
    /// GL `videoLayer` / `avPlayerLayer`). The CGImage carries the
    /// source's alpha (straight for HAP/DXV, premultiplied for AV via
    /// CIContext) so the checkerboard reads through transparent pixels —
    /// the mechanism the HAP arm relies on, and the reason this route is
    /// correct where the non-opaque GL layer was not. Sibling to
    /// videoLayer/avPlayerLayer; only one is visible at a time.
    private let cpuImageLayer = CALayer()
    /// Alpha-checkerboard drawn BEHIND the preview layers so transparent
    /// regions of an alpha-carrying source read as transparent rather
    /// than against flat black. Display-only; gated by
    /// `model.previewSourceHasAlpha` in `applyBackendKind` (shown
    /// whenever the previewed SOURCE carries alpha). It reads through
    /// wherever the active layer is a CGImage on `cpuImageLayer`: the
    /// HAP arm, alpha DXV (DXT5/YG10), and alpha AV (ProRes 4444).
    /// Opaque DXV (DXT1/YCG6) stays on the GL `videoLayer` (opaque,
    /// covers it) and opaque AV on `avPlayerLayer`.
    private let checkerboardLayer = CheckerboardLayer()

    /// Off-main, latest-frame-wins decoder for alpha DXV (DXT5/YG10).
    /// Keeps the heavy `CPURender` decode + CGImage build off the main
    /// thread (DXT5's BC3 software decode at ~5 FPS on main otherwise),
    /// presenting only the finished CGImage on main via `displayCPUImage`.
    /// `[weak self]` in the presenter avoids a retain cycle (the view
    /// owns this decoder). HAP and opaque-DXV paths do not use it.
    private lazy var alphaDecoder = AlphaDXVPreviewDecoder { [weak self] cg in
        self?.displayCPUImage(cg)
    }

    /// Cached Core Image context for alpha-AV (ProRes 4444) frame
    /// conversion. `CIImage(cvPixelBuffer:)` → `createCGImage` honours
    /// the buffer's `kCVImageBufferAlphaChannelMode` (measured: straight
    /// → correctly premultiplied `.premultipliedLast` CGImage; premult
    /// sources handled likewise) AND color-manages the buffer's tagged
    /// colorspace — so no manual straight/premult branch is needed.
    /// Thread-safe; reused across the off-main decode jobs.
    private let ciContext = CIContext()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = containerLayer
        containerLayer.backgroundColor = NSColor.black.cgColor
        containerLayer.addSublayer(videoLayer)
        containerLayer.addSublayer(avPlayerLayer)
        // checkerboard sits just below cpuImageLayer in z-order.
        containerLayer.addSublayer(checkerboardLayer)
        containerLayer.addSublayer(cpuImageLayer)
        avPlayerLayer.videoGravity = .resizeAspect
        cpuImageLayer.contentsGravity = .resizeAspect
        cpuImageLayer.isHidden = true
        checkerboardLayer.isHidden = true
        avPlayerLayer.isHidden = true  // DXV is the initial default
        videoLayer.isHidden = false
        layoutSublayers()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func makeBackingLayer() -> CALayer { containerLayer }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            videoLayer.contentsScale = window.backingScaleFactor
            avPlayerLayer.contentsScale = window.backingScaleFactor
            cpuImageLayer.contentsScale = window.backingScaleFactor
            checkerboardLayer.contentsScale = window.backingScaleFactor
        }
        wireModel()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window = window {
            videoLayer.contentsScale = window.backingScaleFactor
            avPlayerLayer.contentsScale = window.backingScaleFactor
            cpuImageLayer.contentsScale = window.backingScaleFactor
            checkerboardLayer.contentsScale = window.backingScaleFactor
        }
        videoLayer.setNeedsDisplay()
    }

    override func layout() {
        super.layout()
        layoutSublayers()
        videoLayer.setNeedsDisplay()
    }

    /// Fill both sublayers to the bounds of the container. CAOpenGLLayer
    /// uses its own viewport math for aspect-fit; AVPlayerLayer
    /// respects `videoGravity`.
    private func layoutSublayers() {
        // Don't animate the resize — looks janky on window resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        avPlayerLayer.frame = bounds
        cpuImageLayer.frame = bounds
        checkerboardLayer.frame = Self.checkerboardFrame(
            scope: checkerboardScope,
            sourceWidth: model?.sourceWidth ?? 0,
            sourceHeight: model?.sourceHeight ?? 0,
            bounds: bounds)
        checkerboardLayer.setNeedsDisplay()
        CATransaction.commit()
    }

    /// The checkerboard's frame for the current scope. `.fillViewport`
    /// fills the whole preview; `.behindVideoOnly` returns the fitted
    /// video rect (`AVMakeRect` of the source aspect inside bounds),
    /// matching where `cpuImageLayer`'s `.resizeAspect` content actually
    /// sits. Falls back to `bounds` when source dims are unavailable, so
    /// the checker is never left unframed. Pure function — unit-tested.
    static func checkerboardFrame(
        scope: AppSettings.CheckerboardScope,
        sourceWidth: Int, sourceHeight: Int, bounds: CGRect
    ) -> CGRect {
        switch scope {
        case .fillViewport:
            return bounds
        case .behindVideoOnly:
            guard sourceWidth > 0, sourceHeight > 0,
                  bounds.width > 0, bounds.height > 0 else { return bounds }
            return AVMakeRect(
                aspectRatio: CGSize(width: sourceWidth, height: sourceHeight),
                insideRect: bounds)
        }
    }

    private func wireModel() {
        guard let model = model else { return }
        // Wire DXV outbound closures unconditionally — they're no-ops
        // when the backend is .av (the model never invokes them).
        if videoLayer.dxvRenderer == nil {
            videoLayer.dxvRenderer = DXVRenderer()
        }
        model.onDXTFrame = { [weak self] variant, dxtBytes, w, h in
            guard let self = self else { return }
            if variant == .dxt5 {
                // Alpha DXV → CPU-decode to a straight-alpha CGImage and
                // composite via cpuImageLayer (same route as HAP), so the
                // checkerboard reads through transparent pixels. The GL
                // path's S3TC output is straight-alpha and CoreAnimation
                // composites a non-opaque GL layer as premultiplied — that
                // mismatch lost the video, hence this route. `dxtBytes` is
                // the padded S3TC layout CPURender.cgImageFromDXT expects.
                //
                // DXT5's BC3 software decode is heavy, so it runs OFF the
                // main thread (latest-frame-wins) and only the finished
                // CGImage is presented on main — mirroring the smooth
                // opaque-DXV/HAP pattern. `dxtBytes`/`w`/`h` are value
                // copies, safe to hand to the background decode.
                self.alphaDecoder.submit {
                    try? CPURender.cgImageFromDXT(
                        dxtBytes: dxtBytes, variant: .dxt5, width: w, height: h)
                }
            } else {
                // Opaque DXT1 → GL path, unchanged from baseline.
                guard let renderer = self.videoLayer.dxvRenderer else { return }
                self.videoLayer.uploadHook = { [weak renderer] in
                    _ = renderer?.uploadFrame(
                        dxtBytes: dxtBytes,
                        variant: variant,
                        width: w, height: h)
                }
                self.videoLayer.setNeedsDisplay()
            }
        }
        model.onHQFrame = { [weak self] hq, variant in
            guard let self = self else { return }
            if variant == .yg10 {
                // Alpha HQ → straight-alpha CGImage via cpuImageLayer
                // (mirrors DXT5 above + the DXVThumbnail YG10 call). The
                // Y/Co/Cg/A planes already arrive decompressed, so the
                // remaining YCoCg→RGB + CGImage build is lighter than
                // DXT5's BC3 — but still runs off-main via the same
                // latest-frame-wins decoder to keep main free. `hq` is a
                // value struct (its plane arrays copy), safe to hand off.
                self.alphaDecoder.submit {
                    try? CPURender.cgImageFromHQ(
                        y: hq.y, co: hq.co, cg: hq.cg, a: hq.a,
                        width: hq.codedWidth, height: hq.codedHeight,
                        chromaWidth: hq.chromaWidth, chromaHeight: hq.chromaHeight,
                        displayWidth: hq.width)
                }
            } else {
                // Opaque YCG6 → GL path, unchanged from baseline.
                guard let renderer = self.videoLayer.dxvRenderer else { return }
                self.videoLayer.uploadHook = { [weak renderer] in
                    _ = renderer?.uploadHQFrame(hq, variant: variant)
                }
                self.videoLayer.setNeedsDisplay()
            }
        }
        // HAP frames arrive as already-decoded straight-alpha RGBA. Wrap
        // in a CGImage and set as the cpuImageLayer's contents. No GL path.
        model.onRGBAFrame = { [weak self] rgba, w, h in
            guard let self = self,
                  let cg = Self.makeCGImage(rgba: rgba, width: w, height: h)
            else { return }
            self.displayCPUImage(cg)
        }
        // Alpha AV (ProRes 4444) frames arrive as CVPixelBuffers from the
        // model's video-output pump. Convert to a CGImage OFF main via the
        // same latest-frame-wins decoder used by alpha DXV, then present
        // on cpuImageLayer. CIContext honours the buffer's alpha mode +
        // colorspace (see `ciContext` doc); `ctx`/`pb` are captured so the
        // background job doesn't touch `self`.
        model.onAVPixelBuffer = { [weak self] pb in
            guard let self = self else { return }
            let ctx = self.ciContext
            self.alphaDecoder.submit {
                let ci = CIImage(cvPixelBuffer: pb)
                return ctx.createCGImage(ci, from: ci.extent)
            }
        }

        // Apply initial backend state. SwiftUI re-fires
        // PreviewLayerHosting.updateNSView whenever model.backendKind
        // (a @Published) changes; updateNSView calls syncBackend(from:)
        // to push subsequent changes through.
        applyBackendKind(model.backendKind, avPlayer: model.avPlayer,
                         sourceHasAlpha: model.previewSourceHasAlpha)
    }

    /// Set a CPU-decoded straight-alpha CGImage as `cpuImageLayer`'s
    /// contents, with the implicit fade disabled so frames don't
    /// cross-dissolve. Shared by the HAP, DXT5, and YG10 frame paths.
    /// Runs on the main thread (all three callbacks are delivered there).
    private func displayCPUImage(_ cg: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cpuImageLayer.contents = cg
        CATransaction.commit()
    }

    /// Called from PreviewLayerHosting.updateNSView to push the model's
    /// current backend state into the view. Idempotent.
    func syncBackend(from model: PreviewPlayerModel) {
        applyBackendKind(model.backendKind, avPlayer: model.avPlayer,
                         sourceHasAlpha: model.previewSourceHasAlpha)
        // Re-frame the checker for the current clip: a newly-loaded HAP
        // (new source dims) must re-fit the behind-video rect. Cheap +
        // idempotent (CATransaction-disabled layer-frame sets).
        layoutSublayers()
    }

    private func applyBackendKind(
        _ kind: PreviewPlayerModel.BackendKind,
        avPlayer: AVPlayer?,
        sourceHasAlpha: Bool
    ) {
        // Source-alpha gate (replaces the earlier `.hap`-only special
        // case): the checkerboard shows iff the PREVIEWED SOURCE carries
        // alpha. It reads through wherever the active layer is a
        // straight/premult CGImage on `cpuImageLayer` — the HAP arm,
        // alpha DXV (DXT5/YG10), and now alpha AV (ProRes 4444). Opaque
        // sources (DXT1/YCG6 on the GL layer, opaque AV on AVPlayerLayer)
        // hide it.
        checkerboardLayer.isHidden = !sourceHasAlpha
        switch kind {
        case .dxv:
            // Alpha DXV (DXT5/YG10) composites via cpuImageLayer so the
            // checker reads through; opaque DXV (DXT1/YCG6) stays on the
            // GL videoLayer, byte-for-byte identical to baseline.
            avPlayerLayer.player = nil
            avPlayerLayer.isHidden = true
            if sourceHasAlpha {
                videoLayer.isHidden = true
                cpuImageLayer.isHidden = false
            } else {
                videoLayer.isHidden = false
                cpuImageLayer.isHidden = true
            }
        case .av:
            // Alpha AV (ProRes 4444) composites via cpuImageLayer fed by
            // the model's video-output pump — hide AVPlayerLayer (the
            // AVPlayer still drives the clock/audio + the video output).
            // Opaque AV stays on AVPlayerLayer, identical to baseline (no
            // video output, no pump — Step 4).
            videoLayer.isHidden = true
            if sourceHasAlpha {
                avPlayerLayer.player = avPlayer
                avPlayerLayer.isHidden = true
                cpuImageLayer.isHidden = false
            } else {
                avPlayerLayer.player = avPlayer
                avPlayerLayer.isHidden = false
                cpuImageLayer.isHidden = true
            }
        case .hap:
            avPlayerLayer.player = nil
            avPlayerLayer.isHidden = true
            videoLayer.isHidden = true
            cpuImageLayer.isHidden = false
        }
    }

    /// Build a CGImage from HAPPlayer's straight-alpha RGBA bytes.
    /// Format mirrors `GlanceCore.HAPThumbnail.cgImageFromRGBA` exactly:
    /// DeviceRGB, `CGImageAlphaInfo.last` (straight, R-G-B-A), 8 bpc /
    /// 32 bpp, `bytesPerRow = width*4`. The owned `[UInt8]` is copied
    /// into `Data` for the data provider.
    private static func makeCGImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)
    }
}

/// `NSViewRepresentable` bridge for `PreviewLayerHostingNSView`.
/// Wires the model through `makeNSView` + `updateNSView` so SwiftUI's
/// state changes propagate when the user switches preview side or
/// selection — including backend swaps for DXV ↔ non-DXV sources.
struct PreviewLayerHosting: NSViewRepresentable {
    @ObservedObject var model: PreviewPlayerModel
    /// Observing AppSettings makes updateNSView re-fire when the
    /// checkerboard-scope pref changes, so the toggle applies live.
    @ObservedObject private var settings = AppSettings.shared

    func makeNSView(context: Context) -> PreviewLayerHostingNSView {
        let v = PreviewLayerHostingNSView(frame: .zero)
        v.checkerboardScope = settings.checkerboardScope
        v.model = model
        return v
    }

    func updateNSView(_ nsView: PreviewLayerHostingNSView, context: Context) {
        if nsView.model !== model {
            nsView.model = model
        }
        // Push the current checkerboard-scope pref (re-frames the checker
        // live on toggle via the property's didSet).
        nsView.checkerboardScope = settings.checkerboardScope
        // Phase v0.9.0-fix — model.backendKind is @Published, so this
        // closure re-fires whenever the active backend swaps. Push
        // through to the hosting NSView's sublayer visibility logic.
        nsView.syncBackend(from: model)
    }
}

/// Static alpha-transparency checkerboard (two neutral mid-grays, tile in
/// points, crisp at `contentsScale`). Pure display: drawn behind the HAP
/// preview image so transparent regions read as transparent. Redraws on
/// bounds change; nothing here touches decoded pixels or the encode path.
final class CheckerboardLayer: CALayer {
    private let tile: CGFloat = 10
    private let light = CGColor(gray: 0.50, alpha: 1)
    private let dark  = CGColor(gray: 0.34, alpha: 1)

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func draw(in ctx: CGContext) {
        ctx.setFillColor(light)
        ctx.fill(bounds)
        ctx.setFillColor(dark)
        var row = 0
        var y = bounds.minY
        while y < bounds.maxY {
            var x = bounds.minX + (row.isMultiple(of: 2) ? 0 : tile)
            while x < bounds.maxX {
                ctx.fill(CGRect(x: x, y: y, width: tile, height: tile))
                x += 2 * tile
            }
            y += tile
            row += 1
        }
    }
}

/// Off-main, latest-frame-wins preview decoder for alpha DXV
/// (DXT5/YG10). The DXVPlayer hands its decoded frame data to the main
/// thread; building the straight-alpha CGImage there (BC3 software
/// decode for DXT5, YCoCg→RGB for YG10) blocks UI/compositing and drops
/// alpha-DXV preview to ~5 FPS. This moves that work onto a dedicated
/// serial queue and presents only the finished CGImage back on main —
/// mirroring the smooth opaque-DXV (player decode queue → main sets
/// uploadHook) and HAP (background decode → main sets contents) paths.
///
/// Coalescing (latest-frame-wins): at most one decode is in flight and
/// at most one frame pending; a newer submit while one is pending
/// REPLACES the pending one, so playback stays current rather than
/// buffering unbounded behind a slow decode. The serial drain + FIFO
/// main hops keep presentation in order. Mirrors DXVPlayer's own
/// lock-based `servicePending` dispatch shape.
private final class AlphaDXVPreviewDecoder {
    private let queue = DispatchQueue(
        label: "glenc.preview.alphadxv.decode", qos: .userInitiated)
    private let lock = NSLock()
    /// The latest not-yet-decoded job. Overwritten by a newer submit
    /// (the older frame is dropped — intentional latest-frame-wins).
    private var pending: (() -> CGImage?)?
    /// True while a drain is enqueued or running.
    private var scheduled = false
    /// Presenter, called on the main thread with each finished image.
    private let present: (CGImage) -> Void

    init(present: @escaping (CGImage) -> Void) { self.present = present }

    /// Submit a decode job. `decode` runs on the serial queue; its
    /// non-nil CGImage is presented on main, in order. Safe to call
    /// from the main thread (the DXV frame callbacks do).
    func submit(_ decode: @escaping () -> CGImage?) {
        lock.lock()
        pending = decode                 // newer frame coalesces over older
        let needSchedule = !scheduled
        if needSchedule { scheduled = true }
        lock.unlock()
        guard needSchedule else { return }
        queue.async { [weak self] in self?.drain() }
    }

    /// Drain the pending slot until empty (serial queue only).
    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else {
                scheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            if let cg = job() {
                DispatchQueue.main.async { [present] in present(cg) }
            }
        }
    }
}
