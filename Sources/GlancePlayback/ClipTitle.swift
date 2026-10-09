// SPDX-License-Identifier: MIT
import Foundation
import GlanceCore

/// Shared, pure clip-title formatters for the window title / subtitle.
///
/// Moved out of Glance.app (`Sources/Glance/VideoInfoLabel.swift`) into
/// GlancePlayback so every consumer (Glance.app, MaCrate, CueGlance) builds
/// the title from one implementation. Pure string functions — Foundation +
/// GlanceCore only, no AppKit. The generation-aware colorspace label has been
/// on the backlog since v0.7.0: `DXVVariant.displayName` always says "DXV3 …",
/// which is wrong for legacy DXV1/DXV2 (DXDI) files. `DXVVariant.displayName`
/// stays as-is for log output; `colorspaceLabel` below is the UI-only variant
/// that consults `DXVGeneration`.

/// Colorspace label for the window subtitle, aware of codec generation.
///
/// - DXV3 (`.dxv3`): delegates to `DXVVariant.displayName` —
///   "DXV3", "DXV3 alpha", "DXV3 HQ", "DXV3 HQ alpha".
/// - DXV1/DXV2 (`.dxv1`): "DXV1" or "DXV1 alpha". The legacy DXDI
///   format only ever carries `.dxt1` / `.dxt5` (the HQ variants are
///   DXV3-only), so the choice is purely alpha-or-not. versionMajor
///   (DXV1 vs DXV2) is intentionally not surfaced here: it lives in
///   the parsed packet header, not in `DXVMovieIndex`, and reading it
///   would cost a second packet parse just for the label.
public func colorspaceLabel(variant: DXVVariant, generation: DXVGeneration) -> String {
    switch generation {
    case .dxv3:
        return variant.displayName
    case .dxv1:
        switch variant {
        case .dxt5, .yg10: return "DXV1 alpha"
        case .dxt1, .ycg6: return "DXV1"
        }
    }
}

/// Frame-rate label: whole number when within 0.05 of an integer
/// (25.000 → "25fps", 23.976 → "24fps", 29.97 → "30fps"), otherwise
/// one decimal place.
public func fpsLabel(_ fps: Double) -> String {
    let whole = fps.rounded()
    if abs(fps - whole) < 0.05 {
        return "\(Int(whole))fps"
    }
    return String(format: "%.1ffps", fps)
}

/// Duration label: `M:SS`, expanding to `H:MM:SS` at >= 1 hour.
public func durationLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, s)
    }
    return String(format: "%d:%02d", m, s)
}

/// The "WIDTH×HEIGHT · NNfps · DURATION" subtitle string. The codec/variant
/// now lives in the title bracket, so it is intentionally NOT in the subtitle.
public func videoInfoSubtitle(width: Int, height: Int,
                              fps: Double, duration: Double) -> String {
    "\(width)×\(height) · \(fpsLabel(fps)) · \(durationLabel(duration))"
}

/// Codec + loop bracket suffix for the window title: `[<codec>]  [LOOP]`,
/// joined by two spaces (each bracket omitted when not applicable). Byte-
/// identical to the suffix Glance.app's `rebuildTitleSuffix` built inline.
public func clipTitleSuffix(codec: String?, isLooping: Bool) -> String {
    var parts: [String] = []
    if let codec = codec { parts.append("[\(codec)]") }
    if isLooping { parts.append("[LOOP]") }
    return parts.joined(separator: "  ")
}
