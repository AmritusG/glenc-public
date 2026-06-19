// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import GlEncCore

/// Phase 8C-b — pure-function auto-name engine for output filenames.
/// Phase 8C-b-fix — trim brackets switched from frame indices to
/// MM.SS.CC time format (frames-as-time is friendlier to a human eye).
/// Phase 8C-b-fix2 — separators are now all dots within the time and
/// a dash between in/out endpoints (per user preference for cleaner
/// readability).
///
/// Output filename format depends on codec family:
///
///   DXV3 family: `<stem>_DXV {Normal|High} Quality[ With Alpha][ [in-out]].mov`
///   HAP family:  `<stem>_{Hap1|Hap5|HapY}[ [in-out]].mov`
///
/// HAP filenames use the FourCC stem (matches the codec name in
/// stsd, matches Resolume's clip-name conventions for HAP files
/// out of Vidvox tools). DXV3 filenames stay verbose because that's
/// what the v0.5.0 series shipped — bumping just HAP avoids breaking
/// VJ libraries built against the old DXV naming.
///
/// in/out are `MM.SS.CC` time strings computed from frame index +
/// source fps.
///
/// **Separator choice (Phase 8C-b-fix / -fix2):**
///   - `:` is a reserved character in macOS filenames — Finder substitutes
///     it for `/` on display. Dot (`.`) is filename-safe.
///   - Within the time, all separators are dots: `MM.SS.CC`.
///   - Between in and out endpoints in the bracket, a single dash:
///     `[in-out]`. The dash never appears inside a dot-formatted time,
///     so the parse is unambiguous.
///
/// Examples (assume `Clip.mov` stem, 24 fps):
///   - DXT1, no trim:           "Clip_DXV Normal Quality.mov"
///   - DXT5, no trim:           "Clip_DXV Normal Quality With Alpha.mov"
///   - YCG6, no trim:           "Clip_DXV High Quality.mov"
///   - YG10, no trim:           "Clip_DXV High Quality With Alpha.mov"
///   - Hap1, no trim:           "Clip_Hap1.mov"
///   - Hap5, no trim:           "Clip_Hap5.mov"
///   - HapY, no trim:           "Clip_HapY.mov"
///   - DXT1, [24, 180]:         "Clip_DXV Normal Quality [00.01.00-00.07.50].mov"
///   - YG10, [47, 86] @ 30fps:  "Clip_DXV High Quality With Alpha [00.01.56-00.02.86].mov"
///   - Hap5, [24, 180]:         "Clip_Hap5 [00.01.00-00.07.50].mov"
///
/// fps=0 fallback: produces `[00.00.00-00.00.00]`. Surfaces clearly to
/// the user that the source-fps metadata hasn't been populated yet
/// (PreviewPane writes fps back into the job once the preview player
/// loads; refresh fires after).
enum AutoNameEngine {

    /// Generate the suggested filename for a job's current state.
    ///
    /// - Parameters:
    ///   - sourceURL: source movie URL. Output stem is derived from
    ///     `sourceURL.deletingPathExtension().lastPathComponent`.
    ///   - format: codec variant; drives the quality / alpha suffix.
    ///   - inFrame: optional in-frame trim marker. nil = no in trim.
    ///   - outFrame: optional out-frame trim marker. nil = no out trim.
    ///   - fps: source frame rate. Used to convert frame indices to
    ///     `MM-SS.CC` time strings. Pass 0 if unknown; the engine
    ///     emits the `00-00.00` fallback.
    ///   - totalFrames: optional total source frame count, used only
    ///     to resolve `outFrame == nil` into a concrete index for the
    ///     bracket. If nil and outFrame nil but inFrame set, suffix
    ///     renders `[time(inFrame)_time(inFrame)]`.
    ///   - cropRect: optional per-job crop rect in source-pixel space
    ///     (Crop Release Phase G — Q10). When non-nil, the suffix
    ///     carries a `[WxH]` token (lowercase `x`, matching the
    ///     rowCrop UI badge) BEFORE the trim bracket — spatial-first /
    ///     temporal-second mirrors the conceptual model (crop
    ///     identifies which content, trim selects a range of it).
    ///     Always-on when set, including the case where the rect
    ///     equals full source dims (user did Apply with a rect, the
    ///     gesture is honored). No user preference for the format.
    /// - Returns: filename string (no directory). Always ends in `.mov`.
    /// - Parameter outputCodec: Multi-Format Phase 1 — the selected
    ///   parent codec. When `.prores(variant)`, the suffix becomes the
    ///   variant's filename token (e.g. `_ProRes 4444`). When `.dxv` or
    ///   nil (legacy callers), the DXV/HAP `format` branch runs exactly
    ///   as before — byte-identical filenames for every existing path.
    static func suggestedName(
        sourceURL: URL,
        format: DXVFormat,
        outputCodec: OutputCodec? = nil,
        container: OutputContainer = .mov,
        inFrame: Int?,
        outFrame: Int?,
        fps: Double,
        totalFrames: Int? = nil,
        trimFormat: AppSettings.TrimFilenameFormat = .time,
        cropRect: CGRect? = nil
    ) -> String {
        let stem = sourceURL.deletingPathExtension().lastPathComponent

        var suffix: String
        switch outputCodec {
        case .prores(let variant):
            // ProRes outputs name by variant token (e.g. "ProRes 4444").
            suffix = "_\(variant.nameToken)"
        case .h264:
            suffix = "_H.264"
        case .hevc:
            suffix = "_HEVC"
        case .mjpeg:
            suffix = "_MotionJPEG"
        case .dxv, .none:
            switch format.family {
            case .dxv3:
                suffix = "_DXV \(qualityLabel(for: format))"
                if format.hasAlpha {
                    suffix += " With Alpha"
                }
            case .hap:
                // HAP filenames use the FourCC directly — matches the
                // codec name in stsd and Vidvox tooling conventions.
                suffix = "_\(format.label)"
            }
        }

        // Crop Release Phase G — `[WxH]` token before the trim bracket
        // when cropRect is set. `rounded()` is defensive against any
        // future programmatic caller that bypasses the overlay's 4-px
        // snap; pipeline-side validation (Phase F) catches non-integer
        // dims at encode time, but the auto-name engine ignores
        // alignment and only needs a clean integer string. The cropped
        // dims here match the rowCrop UI badge so the user recognizes
        // the format from the queue card.
        if let crop = cropRect {
            let w = Int(crop.width.rounded())
            let h = Int(crop.height.rounded())
            suffix += " [\(w)x\(h)]"
        }

        if inFrame != nil || outFrame != nil {
            let lo = inFrame ?? 0
            let hi: Int
            if let out = outFrame {
                hi = out
            } else if let total = totalFrames, total > 0 {
                hi = total - 1
            } else {
                hi = lo
            }
            let (lowEnd, highEnd) = (min(lo, hi), max(lo, hi))
            // Phase 7B-a — bracket format is user-settable. Time format
            // (Phase 8C-b-fix2 default) reads MM.SS.CC; frame-indices
            // format (legacy) reads raw integers.
            let bracket: String
            switch trimFormat {
            case .time:
                let inTime = formatTime(frameIndex: lowEnd, fps: fps)
                let outTime = formatTime(frameIndex: highEnd, fps: fps)
                bracket = "\(inTime)-\(outTime)"
            case .frameIndices:
                bracket = "\(lowEnd)-\(highEnd)"
            }
            suffix += " [\(bracket)]"
        }

        // Container drives the extension: .mov for DXV/HAP/ProRes (and
        // H.264/HEVC in a QuickTime container); .mp4 for H.264/HEVC when
        // the user picks MPEG-4. Default `.mov` keeps every pre-2a name
        // byte-identical.
        return "\(stem)\(suffix).\(container.ext)"
    }

    /// Format a frame index as `MM.SS.CC` time. Dot separators
    /// (rather than colon) keep the resulting filename macOS-safe —
    /// Finder substitutes `:` for `/` on display, which would garble
    /// the name. Centiseconds (`.CC`) match common VJ-tool conventions
    /// (Resolume's clip browser shows two fractional digits).
    ///
    /// fps ≤ 0 produces `00.00.00` (Phase 8C-b-fix fallback before
    /// PreviewPlayerModel populates the job's known fps).
    private static func formatTime(frameIndex: Int, fps: Double) -> String {
        guard fps > 0 else { return "00.00.00" }
        let totalSeconds = max(0.0, Double(frameIndex) / fps)
        let minutes = Int(totalSeconds) / 60
        let secondsPart = totalSeconds - Double(minutes * 60)
        let seconds = Int(secondsPart)
        // Truncate (not round) the centisecond component so we never
        // overshoot into the next second on the boundary. e.g. frame 60
        // @ 24fps = 2.5s exactly → 00.02.50 (not 00.02.51 from rounding).
        let centiseconds = Int((secondsPart - Double(seconds)) * 100)
        return String(format: "%02d.%02d.%02d", minutes, seconds, centiseconds)
    }

    /// v0.9.2 Phase G — collision-free URL resolver. Given a desired
    /// output URL, return a URL guaranteed not to collide with an
    /// existing file on disk by appending `_N` before the extension.
    ///
    /// Algorithm (highest-N scan, NOT blind-_2):
    ///   1. If `url` doesn't exist → return it unchanged.
    ///   2. Enumerate sibling files in `url`'s parent directory.
    ///      Match names of the form `<stem>_<digits>.<ext>` (or
    ///      `<stem>_<digits>` if there's no extension).
    ///   3. The maximum N across those matches (treating the base
    ///      file as N=1 implicitly) drives the answer: return
    ///      `<stem>_(maxN+1).<ext>`.
    ///
    /// This means:
    ///   - dense prefix (_2, _3, _4 exist) → return _5
    ///   - sparse (_2, _4 exist, _3 missing) → return _5 (NOT _3 —
    ///     filling gaps would break the chronological reading where
    ///     "_4 is newer than _2; my new file _5 is newest")
    ///   - no _N siblings → return _2
    ///
    /// Pure-function except for the filesystem-listing call. Tests
    /// inject `listSiblings` for hermetic coverage; production uses
    /// `FileManager.default.contentsOfDirectory`.
    static func collisionFreeURL(
        _ url: URL,
        listSiblings: ((URL) -> [URL])? = nil
    ) -> URL {
        let fm = FileManager.default
        let baseExists: Bool = {
            if listSiblings != nil {
                // Test path: existence determined by whether `url`
                // appears among listSiblings' output.
                let dir = url.deletingLastPathComponent()
                let siblings = listSiblings!(dir)
                return siblings.contains(where: { $0.lastPathComponent == url.lastPathComponent })
            }
            return fm.fileExists(atPath: url.path)
        }()
        guard baseExists else { return url }

        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        let prefix = "\(stem)_"
        let suffix = ext.isEmpty ? "" : ".\(ext)"

        let siblings: [URL]
        if let lister = listSiblings {
            siblings = lister(dir)
        } else {
            siblings = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil)) ?? []
        }

        // Base file is N=1 conceptually.
        var maxN = 1
        for sib in siblings {
            let name = sib.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            // Strip prefix + suffix, parse the middle as an integer.
            let middle = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            // Reject empty or non-numeric middles (defends against
            // siblings like "<stem>_foo.<ext>" — they're not _N rename
            // results).
            if !middle.isEmpty, middle.allSatisfy(\.isNumber),
               let n = Int(middle), n > maxN {
                maxN = n
            }
        }
        let nextN = maxN + 1
        let nextName = ext.isEmpty ? "\(stem)_\(nextN)" : "\(stem)_\(nextN).\(ext)"
        return dir.appendingPathComponent(nextName)
    }

    /// Mirror of `DXVFormat.tier` mapped to the user-visible string.
    /// Kept in this engine rather than added to `DXVFormat` so the
    /// label-string surface stays GlEnc-side (could change for
    /// localization without bumping the library API).
    private static func qualityLabel(for format: DXVFormat) -> String {
        switch format.tier {
        case .normal: return "Normal Quality"
        case .hq:     return "High Quality"
        }
    }
}
