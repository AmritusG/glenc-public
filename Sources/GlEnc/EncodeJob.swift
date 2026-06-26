// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import AVFoundation
import CoreMedia
import GlEncCore

/// One unit of work in the encode queue.
struct EncodeJob: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    /// DXV/HAP format. Source of truth for the `.dxv` codec path —
    /// preview backend, AutoName DXV branch, and the DXV/HAP submenu
    /// all read this. When `outputCodec` is `.prores` this holds the
    /// last DXV selection (so switching back restores it).
    var format: DXVFormat
    /// Multi-Format Phase 1 — the selected output codec. Defaults to
    /// `.dxv(format)` so every pre-existing path is byte-identical.
    /// `.prores(variant)` routes the encode through VideoToolbox; the
    /// dispatch (`EncodeQueue.startEncode`) branches on this.
    var outputCodec: OutputCodec
    /// Output container. ProRes/DXV/HAP → `.mov`; H.264/HEVC (Phase 2a)
    /// may also pick `.mp4` (`OutputCodec.allowedContainers`). Drives the
    /// output filename extension (AutoName) + the writer's `AVFileType`.
    var outputContainer: OutputContainer = .mov
    /// Multi-Format Phase 2a — rate-control + profile knobs for the
    /// VideoToolbox inter-frame codecs (H.264 / HEVC). Applies only when
    /// `outputCodec` is `.h264`/`.hevc`; ProRes/DXV/HAP ignore it. Edited
    /// in the per-job Advanced popover.
    var videoSettings: VideoEncodeSettings = .default

    /// Slice 4 — HAP chunked-section count (1–64; 1 = single section,
    /// byte-identical to pre-Slice-4 output). Honoured only when the
    /// resolved `format` is a HAP variant (`format.family == .hap`);
    /// DXV3 variants ignore it. Seeded from `AppSettings.defaultHapChunks`
    /// at job-add and edited per-row via the codec row's Chunks stepper.
    /// Flows into `EncodeRequest.hapChunks` at encode time.
    var hapChunks: Int = 1

    // MARK: - Audio (Multi-Format Phase 4)

    /// Carry source audio into the output (default ON — Alley parity); the
    /// per-row toggle STRIPS it. Inert when `sourceHasAudio == false`.
    var audioEnabled: Bool = true
    /// Output sample rate. `.original` = decode-to-PCM at source rate;
    /// the explicit rates resample.
    var audioRate: AudioRate = .original
    /// Whether the SOURCE has an audio track — probed async at add
    /// (mirrors `sourceHasAlpha`). nil until resolved. Drives the inert
    /// state of the audio controls.
    var sourceHasAudio: Bool? = nil
    /// Whether the SOURCE file carries an alpha channel. Probed
    /// asynchronously at job-add (`EncodeQueue.addJobs`); nil until the
    /// probe completes (or if it couldn't decide). Drives ProRes
    /// alpha-steering: an alpha source defaults ProRes to 4444, and a
    /// non-4444 ProRes choice on an alpha source surfaces the
    /// "alpha will be flattened" note.
    var sourceHasAlpha: Bool? = nil
    var status: Status
    var progress: Double       // 0...1
    var outputURL: URL?
    /// Human-readable failure reason populated when `status == .failed`.
    /// Reads "Cancelled" for user-cancelled jobs and the encoder's
    /// `Error` description otherwise. Phase 7B will surface this in the
    /// row's Actions column / a tooltip.
    var errorMessage: String?
    /// Fix-Brief 2 — non-fatal audio warning, distinct from `errorMessage`
    /// (which is failure-only). Set when audio was ENABLED and the source
    /// HAS an audio track but the audio could not be produced correctly
    /// (undecodable, unsupported channel count, undeterminable rate, sink
    /// rejected the audio). The job still completes `.done` with its
    /// (silent) video; the row surfaces this so the user sees "audio
    /// unavailable" WITHOUT opening the file. nil = audio fine, or the
    /// source genuinely had no audio (silent-no-warning is correct).
    var audioWarning: String?
    /// Which file the Phase 8B preview pane displays for this job —
    /// the original source, or the encoded output. Defaults to source;
    /// the UI snaps to output once `status == .done` if the user hasn't
    /// touched the toggle. Force-locked to source while `status != .done`.
    var previewSide: PreviewSide = .source

    /// Phase 8B: which file the preview pane shows for this row.
    enum PreviewSide: String, Equatable {
        case source
        case output
    }

    /// Phase 8C-a — optional in/out trim points. nil = no trim (encode
    /// the full clip, current behavior). When at least one is set, the
    /// EncodePipeline emits only the frames in `[inFrame, outFrame]`
    /// (both inclusive). Source frame indexing, 0-based.
    ///
    /// Storage stays on `EncodeJob` so trim survives selection swaps in
    /// the preview pane. `PreviewPlayerModel` mirrors these into its
    /// own `@Published`s for ScrubBar binding; PreviewPane reconciles
    /// the two via `.onChange` modifiers.
    var inFrame: Int? = nil
    var outFrame: Int? = nil

    /// Convenience predicate. True when either bound is set; drives
    /// the UI's "trim active" affordances + EncodeQueue's
    /// frame-range computation.
    var isTrimmed: Bool {
        inFrame != nil || outFrame != nil
    }

    /// Resolve `inFrame` / `outFrame` (which may be nil) into a pair
    /// of concrete in-range indices for use by `EncodePipeline`. Both
    /// endpoints inclusive. Tolerates swapped (user-error) and
    /// out-of-bounds values:
    ///   - nil in  → 0
    ///   - nil out → totalFrames - 1
    ///   - negative or past-end → clamped
    ///   - in > out → swapped so the smaller becomes `in`
    func resolvedTrimRange(totalFrames: Int) -> (in: Int, out: Int) {
        guard totalFrames > 0 else { return (0, 0) }
        let last = totalFrames - 1
        let lo = max(0, min(last, inFrame ?? 0))
        let hi = max(0, min(last, outFrame ?? last))
        return (min(lo, hi), max(lo, hi))
    }

    /// Phase 8C-b — user-facing output filename, populated from the
    /// AutoNameEngine on init and refreshed when format / trim
    /// changes (gated by `outputNameOverridden`). The actual encode
    /// path reads this; the legacy `defaultOutputURL` is now derived
    /// from `outputName` so tests + callers that referenced the old
    /// path keep working unchanged.
    var outputName: String = ""

    /// Phase 8C-b — flag indicating the user manually edited
    /// `outputName`. When true, the queue's auto-refresh helper
    /// skips the row so codec/trim changes don't clobber the edit.
    /// Cleared by `resetOutputNameToAuto()` or by re-edits after
    /// reset.
    var outputNameOverridden: Bool = false

    /// Phase 8C-b-fix — source fps, discovered lazily when the preview
    /// pane loads this job's source. Used by `AutoNameEngine` to
    /// convert trim frame indices into MM-SS.CC time-format brackets.
    /// nil until the source has been previewed at least once. When
    /// the user sets a trim before fps is known, the engine emits
    /// `[00-00.00_00-00.00]` as a clear "fps not loaded yet"
    /// placeholder; `PreviewPane.onChange(of: model.frameRate)` writes
    /// the discovered fps and triggers a re-refresh.
    var sourceFPS: Double?

    /// Phase 4.1 — total source frame count, probed at add (same
    /// `makeSourceReader` pass as `sourceFPS`). Lets the AutoName trim
    /// bracket resolve an open-ended out point ("→ end") to the clip's
    /// real end time instead of duplicating the in-point.
    var sourceFrameCount: Int?

    /// Fix-Brief B — authoritative source pixel dimensions, captured at
    /// add-time by `probeSourceTiming` (the now-validated encode reader),
    /// independent of the live preview's async decode. The crop editor's
    /// numeric clamp reads these so it works the instant a row is edited,
    /// even before the preview has decoded a frame. `nil` until the probe
    /// resolves (the probe is a header read, so this is brief); a probe
    /// failure marks the job `.failed` rather than leaving these nil-and-
    /// usable. (Jobs aren't persisted, so no Codable migration.)
    var sourceWidth: Int?
    var sourceHeight: Int?

    /// Crop Release Phase B — per-job source-pixel crop rectangle.
    /// `nil` means no crop (the full source frame is used — the
    /// default). Origin is top-left per CROP_PLAN.md Q2: `minY = 0`
    /// is the top row of source pixels, matching `CVPixelBuffer` row
    /// indexing and the encoder's BGRA byte layout — no coordinate
    /// flip anywhere. The rect's X / Y / width / height are each
    /// 4-pixel-aligned (L3); enforcement is the preview-overlay snap
    /// (Phase D), not this field. Semantically applied BEFORE
    /// `outputSize` (L2: crop → resize), which is why it is declared
    /// ahead of the resize fields. The EncodePipeline crop stage
    /// (Phase F) consumes this value; at Phase B the field is
    /// data-model-only. Crop has no global default — there is
    /// deliberately no `AppSettings.defaultCropRect` (CROP_PLAN.md
    /// Q8 / CROP_RESIZE_PLAN.md §3).
    var cropRect: CGRect? = nil

    /// Resize Release Phase C — per-job output size. `.original` means
    /// no resize (the encoder receives source dims). Set by the per-row
    /// Output Size menu (Phase F UI work) or inherited from
    /// `AppSettings.defaultOutputSize` at job-creation time. The
    /// EncodePipeline transform stage (Phase E) consumes this value;
    /// at Phase C the field is data-model-only.
    var outputSize: OutputSize = .original

    /// Resize Release Phase C — per-job resize-filter choice. `.auto`
    /// resolves at frame-time by scale direction (downscale → Lanczos,
    /// upscale → bilinear). Set by the per-row Quality menu (Phase F
    /// UI work) or inherited from `AppSettings.defaultResizeQuality`
    /// at job-creation time. Consumed by the EncodePipeline transform
    /// stage (Phase E).
    var resizeQuality: ResizeQuality = .auto

    /// Resize Release Phase G — per-job aspect handling. `.letterbox`
    /// fits the source aspect inside the target rect and fills the
    /// remainder with opaque black (default per CROP_RESIZE_PLAN.md
    /// Q3); `.distortToFill` stretches non-uniformly to target dims.
    /// Ignored on `.original` and when source aspect already matches
    /// target aspect. Set by the per-row Aspect menu (Phase G UI) or
    /// inherited from `AppSettings.defaultAspectMode` at job-creation
    /// time.
    var aspectMode: AspectMode = .letterbox

    /// Recompute `outputName` from the AutoNameEngine using current
    /// fields. Caller is responsible for gating on
    /// `!outputNameOverridden` when the call is reactive (i.e. fired
    /// by an external change); the reset path calls this directly
    /// after clearing the flag.
    /// Phase 7B-a — `trimFormat` is an explicit parameter rather than
    /// reaching into `AppSettings.shared` from this struct method.
    /// Swift actor-isolation rules don't allow a non-isolated struct
    /// mutating-func to read from a @MainActor singleton; passing the
    /// value down from the caller (which IS @MainActor) is cleaner
    /// than `MainActor.assumeIsolated` gymnastics. Defaults to `.time`
    /// so existing tests keep working without explicit setting passes.
    mutating func setOutputNameAuto(trimFormat: AppSettings.TrimFilenameFormat = .time) {
        self.outputName = AutoNameEngine.suggestedName(
            sourceURL: sourceURL,
            format: format,
            outputCodec: self.outputCodec,
            container: self.outputContainer,
            inFrame: inFrame,
            outFrame: outFrame,
            fps: sourceFPS ?? 0,
            // Phase 4.1 — resolve an open-ended out point ("→ end") to the
            // clip's real end time instead of duplicating the in-point.
            totalFrames: sourceFrameCount,
            trimFormat: trimFormat,
            // Crop Release Phase G.1 — forward the job's cropRect so
            // the engine's `[WxH]` token (Phase G) actually appears in
            // the auto-refresh path. nil hits the engine's no-token
            // default — byte-identical to pre-G for non-cropped jobs.
            cropRect: cropRect
        )
    }

    /// Drop the user override and re-derive `outputName` from the
    /// AutoNameEngine. Bound to the row's reset (↻) button.
    mutating func resetOutputNameToAuto(
        trimFormat: AppSettings.TrimFilenameFormat = .time
    ) {
        self.outputNameOverridden = false
        setOutputNameAuto(trimFormat: trimFormat)
    }

    init(
        sourceURL: URL,
        format: DXVFormat = .dxt1,
        outputSize: OutputSize = .original,
        resizeQuality: ResizeQuality = .auto,
        aspectMode: AspectMode = .letterbox,
        cropRect: CGRect? = nil,
        audioEnabled: Bool = true,
        audioRate: AudioRate = .original,
        hapChunks: Int = 1
    ) {
        self.audioEnabled = audioEnabled
        self.audioRate = audioRate
        // Slice 4 — clamp defensively; callers seed from the persisted
        // default (already clamped) and the stepper enforces 1...64, so
        // this only guards programmatic construction.
        self.hapChunks = min(64, max(1, hapChunks))
        self.id = UUID()
        self.sourceURL = sourceURL
        self.format = format
        // Default to the DXV/HAP path — byte-identical to pre-Phase-1
        // behavior. The picker switches this to `.prores(...)` on demand.
        self.outputCodec = .dxv(format)
        self.status = .queued
        self.progress = 0
        self.outputURL = nil
        self.errorMessage = nil
        self.previewSide = .source
        self.inFrame = nil
        self.outFrame = nil
        self.outputNameOverridden = false
        self.sourceFPS = nil
        self.sourceFrameCount = nil
        self.cropRect = cropRect
        self.outputSize = outputSize
        self.resizeQuality = resizeQuality
        self.aspectMode = aspectMode
        // Phase 8C-b — derive the initial outputName from the same
        // AutoNameEngine that drives auto-refresh on codec/trim
        // changes. This keeps the "freshly-added row already shows
        // its filename" UX consistent with the auto-update path.
        // Phase 8C-b-fix: fps is unknown at this point (preview hasn't
        // loaded yet); pass 0 so the engine emits its placeholder
        // when trim isn't set. No trim at init → no bracket → fps
        // value is irrelevant for the initial render.
        self.outputName = AutoNameEngine.suggestedName(
            sourceURL: sourceURL,
            format: format,
            outputCodec: .dxv(format),
            container: .mov,
            inFrame: nil,
            outFrame: nil,
            fps: 0,
            // Crop Release Phase G.1 — a job constructed with a
            // cropRect carries the `[WxH]` token from its first
            // auto-name render. The init parameter `cropRect` is the
            // same value just assigned to `self.cropRect` above.
            cropRect: cropRect)
    }

    enum Status: String, Equatable {
        case queued
        case encoding
        case done
        case failed

        var label: String {
            switch self {
            case .queued:   return "Queued"
            case .encoding: return "Encoding"
            case .done:     return "Done"
            case .failed:   return "Failed"
            }
        }
    }

    /// Output URL: directory next to the source, basename from
    /// `outputName`. Phase 8C-b made `outputName` the source of truth
    /// (computed from the AutoNameEngine on init + on format/trim
    /// changes; user-editable). Pre-8C-b callers that referenced
    /// `defaultOutputURL` continue to work — the path matches the
    /// VersaTale convention exactly when the user hasn't overridden.
    var defaultOutputURL: URL {
        let dir = sourceURL.deletingLastPathComponent()
        return dir.appendingPathComponent(outputName)
    }

    // MARK: - Alpha steering (Multi-Format Phase 1)

    /// The ProRes variant to default to when switching this job to the
    /// ProRes family. An alpha source → 4444 (preserve transparency);
    /// otherwise 422. When the source-alpha probe hasn't resolved yet
    /// (`sourceHasAlpha == nil`), fall back to the current DXV alpha
    /// intent (the user picked a With-Alpha DXV format → they care).
    var steeredProResVariant: ProResVariant {
        let alpha = sourceHasAlpha ?? format.hasAlpha
        return alpha ? .proRes4444 : .proRes422
    }

    /// True when the current selection would silently drop a present
    /// alpha channel — a non-4444 ProRes variant on a source that has
    /// (or is intended to carry) alpha. Drives the visible flatten note.
    var alphaWillBeFlattened: Bool {
        guard case .prores(let v) = outputCodec, !v.hasAlpha else { return false }
        return sourceHasAlpha ?? format.hasAlpha
    }

    /// Best-effort source-fps probe via `makeSourceReader` — works for
    /// DXV/HAP sources too (AVFoundation can't read DXV frame rate, which
    /// is why a DXV source's trim bracket showed the `00.00.00` placeholder
    /// until the preview loaded). Probed at add so the AutoName time
    /// bracket is correct regardless of preview/codec-switch timing.
    /// Fix-Brief B — captures the authoritative source dims alongside
    /// fps/count, and SURFACES a reader failure instead of swallowing it
    /// with `try?`. A malformed source (zero/oversized dims, no video
    /// track, …) makes `makeSourceReader` throw a `SourceReaderError`
    /// (validated at the reader boundary by 313d520); this rethrows so the
    /// caller can mark the job failed-with-reason at add-time rather than
    /// silently adding a row that renders garbage. A successfully-
    /// constructed reader has positive dims and fps>0 (else its init
    /// would have thrown), so the returned values are always usable.
    static func probeSourceTiming(
        _ url: URL
    ) async throws -> (width: Int, height: Int, fps: Double, frameCount: Int) {
        let reader = try await makeSourceReader(for: url, sourceAlphaInfo: .last)
        return (reader.sourceWidth, reader.sourceHeight,
                reader.sourceFPS, reader.totalFrameCount)
    }

    /// Best-effort source-alpha probe. Prefers the authoritative,
    /// decode-free `kCMFormatDescriptionExtension_ContainsAlphaChannel`
    /// flag — this distinguishes a genuinely-alpha ProRes 4444 from an
    /// *opaque* 4444 (both are subtype `ap4h`/`ap4x`), which the old
    /// subtype-only mapping over-detected. Falls back to the codec-
    /// subtype mapping for codecs whose format descriptions don't carry
    /// the extension (HAP, where AVFoundation surfaces only the FourCC).
    /// Returns nil when it can't decide (no track / unknown codec) so
    /// callers fall back to alpha intent rather than asserting opacity.
    ///
    /// Used by the preview source-alpha gate (`PreviewPlayerModel`) and
    /// the encode-queue ProRes alpha-steering (`EncodeQueue` →
    /// `EncodeJob.sourceHasAlpha`, which drives only the UI default
    /// variant + flatten note — NOT encoded output; the encoders derive
    /// alpha from the decoded frame's `CGImageAlphaInfo` independently).
    static func probeSourceAlpha(_ url: URL) async -> Bool? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fmts = try? await track.load(.formatDescriptions),
              let fmt = fmts.first else {
            return nil
        }
        // Authoritative when present: the decoder's own "frames carry an
        // alpha channel" flag (measured present on ProRes 4444 with
        // alpha; correctly absent/false on opaque 4444).
        let exts = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] ?? [:]
        if let containsAlpha =
            exts[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? NSNumber {
            return containsAlpha.boolValue
        }
        // Fallback for codecs without the extension (notably HAP, where
        // AVFoundation exposes only the FourCC).
        let st = CMFormatDescriptionGetMediaSubType(fmt)
        let bytes = [UInt8((st >> 24) & 0xff), UInt8((st >> 16) & 0xff),
                     UInt8((st >> 8) & 0xff), UInt8(st & 0xff)]
        let tag = String(bytes: bytes, encoding: .ascii) ?? ""
        switch tag {
        case "ap4h", "ap4x", "Hap5", "HapM", "HapA":
            return true
        case "apcn", "apch", "apcs", "apco", "HapY", "Hap1":
            return false
        default:
            return nil
        }
    }
}
