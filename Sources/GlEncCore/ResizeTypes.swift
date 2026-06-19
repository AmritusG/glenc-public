// SPDX-License-Identifier: MIT
/*
 * ResizeTypes.swift — Resize Release Phase B (v0.9.4-pending).
 *
 * Pure value types for the Resize release. NO EncodeJob, pipeline,
 * UI, or persistence wiring — those are Phases C onward. This file
 * defines:
 *
 *   - ResizeQuality:      auto / nearest / bilinear / lanczos
 *   - StandardResolution: 16-entry preset table
 *   - OutputSize:         enum of .original / .preset / .custom
 *
 * Locked decisions (CROP_RESIZE_PLAN.md L1-L3 + Q1-Q5, RESIZE_PLAN.md
 * Q1-Q3):
 *
 *   - L3: every dimension reaching an encoder is 4-pixel-aligned.
 *     All 16 presets are 4-mult on both axes; ResizeTypesTests
 *     guards this. Q3 confirmed L3 holds for HQ too (no codec-
 *     conditional 16-mult rounding — the HQ-16px Arena gate passed).
 *   - Q1: Auto's upscale branch resolves to .bilinear (downscale
 *     stays .lanczos per CROP_RESIZE_PLAN.md Q4).
 *   - Q2: Auto has NO soft scale-threshold — purely direction-
 *     based comparison of output-vs-source dims.
 *   - Q5: custom presets persisted with user names. NamedSize is
 *     defined elsewhere (Phase H); this file's .custom carries
 *     a bare (width, height) without a name.
 *
 * Defined here as a single feature-bundled file to match the
 * UITypes.swift precedent. Both targets (GlEncCore for the resize
 * pipeline + GlEnc for the UI bindings) import these via
 * `import GlEncCore`.
 */

import Foundation

// MARK: - ResizeQuality

/// User-facing resize-filter choice, persisted per-job and as the
/// default in AppSettings (Phase C wiring).
///
/// `.auto` resolves at frame-time to a concrete filter based on the
/// scale direction (see `resolved(forScale:)`). The non-auto cases
/// are explicit overrides.
///
/// **Auto is NOT content-aware.** It cannot detect pixel-art vs
/// photographic content. The scale-direction heuristic handles the
/// common case (anti-alias on downscale, soften on upscale) without
/// user thought, but `.nearest` remains the deliberate manual
/// override for content that wants hard edges (pixel-art, voxel,
/// retro UI). UI tooltips must surface this contract — see
/// CROP_RESIZE_PLAN.md Q4 for the canonical wording.
public enum ResizeQuality: String, Hashable, Codable, CaseIterable, Sendable {
    /// Direction-based: downscale → Lanczos, upscale → bilinear,
    /// equal → no-op. NOT content-aware.
    case auto

    /// Box-fetch with no interpolation. Preserves hard edges
    /// (pixel-art, voxel, retro UI). Cheapest but visibly blocky
    /// on photographic content.
    case nearest

    /// Linear interpolation. Soft, no ringing. Standard upscale
    /// default in most video pipelines; what Auto picks on upscale.
    case bilinear

    /// Sharpest reasonable filter, multi-tap kernel. Best for
    /// downscaling (suppresses aliasing); may introduce visible
    /// ringing on already-sharp source when upscaling. What Auto
    /// picks on downscale.
    case lanczos

    /// User-visible label for the per-row + defaults-row Quality
    /// menu (Phase F UI work). Kept on the type so the UI binding
    /// doesn't duplicate the canonical wording.
    public var displayLabel: String {
        switch self {
        case .auto:     return "Auto"
        case .nearest:  return "Nearest"
        case .bilinear: return "Bilinear"
        case .lanczos:  return "Lanczos"
        }
    }

    /// Resolve `.auto` to a concrete filter given the scale
    /// direction. The non-auto cases return themselves.
    ///
    /// Mapping (Q1 + Q2 locked):
    ///   - `sourceW × sourceH == outputW × outputH`:
    ///       Auto resolves to `.bilinear` (no-op pass-through is
    ///       the caller's responsibility — equal-dims is moot).
    ///   - Output smaller than source on BOTH axes ("downscale"):
    ///       Auto resolves to `.lanczos`.
    ///   - Otherwise ("upscale" — output larger on either axis):
    ///       Auto resolves to `.bilinear` (Q1).
    ///
    /// No soft scale-threshold (Q2). Even a 1-pixel difference is
    /// classified strictly by direction.
    ///
    /// "Downscale" requires both axes to be ≤ source. A mixed case
    /// (e.g. width shrinks, height grows) counts as upscale — any
    /// growth-axis benefits from the softer filter; the
    /// shrink-axis's aliasing is the secondary concern.
    public func resolved(forSourceWidth sourceW: Int, sourceHeight sourceH: Int,
                         outputWidth outputW: Int, outputHeight outputH: Int) -> ResizeQuality {
        switch self {
        case .nearest, .bilinear, .lanczos:
            return self
        case .auto:
            if outputW == sourceW && outputH == sourceH {
                // Equal dims — caller treats as no-op. Returning
                // .bilinear here is a neutral default that lets the
                // pipeline construct a buffer of the right shape;
                // the resizer can detect equal-dims and skip the
                // call entirely. The exact branch the resizer takes
                // is up to it; this method's job is only to remove
                // `.auto` from the type system.
                return .bilinear
            }
            let isDownscale = (outputW <= sourceW) && (outputH <= sourceH)
            return isDownscale ? .lanczos : .bilinear
        }
    }
}

// MARK: - StandardResolution

/// The 16-entry preset table the Output Size dropdown surfaces.
/// Every entry is 4-pixel-multiple on both axes (verified by
/// `ResizeTypesTests.testAllPresetsAre4PixelLegal`).
///
/// Phase B fixes the table; Phase F's "Custom…" sheet and Phase H's
/// persisted user-named customs are separate concerns
/// (CROP_RESIZE_PLAN.md Q5).
public enum StandardResolution: String, CaseIterable, Codable, Hashable, Sendable {
    // HD broadcast / streaming
    case hd_1280_720
    case fhd_1920_1080
    case qhd_2560_1440
    case uhd_3840_2160

    // DCI cinema
    case dci_2048_1080
    case dci_4096_2160

    // Square (LED panels, social)
    case sq_1024
    case sq_1080
    case sq_2048

    // Vertical (TikTok / Reels / Stories)
    case v_720_1280
    case v_1080_1920
    case v_1440_2560

    /// The numeric `(width, height)` of this preset.
    public var dimensions: (width: Int, height: Int) {
        switch self {
        // HD/UHD
        case .hd_1280_720:   return (1280, 720)
        case .fhd_1920_1080: return (1920, 1080)
        case .qhd_2560_1440: return (2560, 1440)
        case .uhd_3840_2160: return (3840, 2160)
        // DCI
        case .dci_2048_1080: return (2048, 1080)
        case .dci_4096_2160: return (4096, 2160)
        // Square
        case .sq_1024:       return (1024, 1024)
        case .sq_1080:       return (1080, 1080)
        case .sq_2048:       return (2048, 2048)
        // Vertical
        case .v_720_1280:    return (720, 1280)
        case .v_1080_1920:   return (1080, 1920)
        case .v_1440_2560:   return (1440, 2560)
        }
    }

    /// User-visible label following the plan's "<Category> —
    /// WIDTH×HEIGHT" form (RESIZE_PLAN.md §4).
    public var displayLabel: String {
        switch self {
        case .hd_1280_720:   return "HD 720p — 1280×720"
        case .fhd_1920_1080: return "Full HD — 1920×1080"
        case .qhd_2560_1440: return "QHD — 2560×1440"
        case .uhd_3840_2160: return "UHD 4K — 3840×2160"
        case .dci_2048_1080: return "DCI 2K — 2048×1080"
        case .dci_4096_2160: return "DCI 4K — 4096×2160"
        case .sq_1024:       return "Square — 1024×1024"
        case .sq_1080:       return "Square — 1080×1080"
        case .sq_2048:       return "Square — 2048×2048"
        case .v_720_1280:    return "Vertical — 720×1280"
        case .v_1080_1920:   return "Vertical — 1080×1920"
        case .v_1440_2560:   return "Vertical — 1440×2560"
        }
    }
}

// MARK: - AspectMode

/// Per-job aspect-handling mode for the transform stage (Phase G).
///
/// When the chosen `OutputSize` aspect ratio differs from the source
/// aspect ratio, this enum picks between two behaviors:
///
///   - `.letterbox` (default per CROP_RESIZE_PLAN.md Q3): preserve
///     the source aspect by fitting the resized image into a centered
///     rect inside the target dims and filling the remainder with
///     opaque black. The bars are *real encoded pixels* — a genuine
///     file-size cost.
///   - `.distortToFill`: stretch-to-fit. Non-uniform scale straight
///     to target dims. The rare "stretch to a circular LED" override.
///
/// When source aspect == target aspect, the two modes are
/// equivalent — both produce a straight resize with no bars. The
/// `.original` no-op path ignores this enum entirely.
public enum AspectMode: String, Hashable, Codable, CaseIterable, Sendable {
    case letterbox
    case distortToFill

    /// User-visible label used by the per-row Aspect menu + the
    /// defaults-row menu (Phase G UI).
    public var displayLabel: String {
        switch self {
        case .letterbox:     return "Fit (letterbox)"
        case .distortToFill: return "Distort to fill"
        }
    }
}

// MARK: - NamedSize (Phase H — Q5)

/// A user-named custom preset. Lives in `AppSettings.customPresets`
/// (a JSON-persisted array) and surfaces in the Output Size menu's
/// "My Sizes" section.
///
/// Named presets are a UI shortcut: applying one sets a job's
/// `outputSize = .custom(width, height)`, the same shape the
/// Custom… sheet produces. `OutputSize` stays the 3-case enum —
/// there is no `.named` case. A job with `outputSize ==
/// .custom(1500, 844)` is identical regardless of whether the
/// user reached it via the Custom… sheet or by clicking a saved
/// "Wall A" preset.
///
/// Invariants:
///   - `width` and `height` are expected to be positive and
///     4-pixel-aligned by the time they reach this type. The
///     Custom… sheet rounds before saving; programmatic callers
///     are responsible for the same alignment.
///   - `name` is non-empty after trimming whitespace. Empty names
///     are rejected at the Save UI boundary, not in this type.
///   - `id` is a UUID for stable identity across persistence
///     round-trips and list edits.
public struct NamedSize: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var width: Int
    public var height: Int

    public init(id: UUID = UUID(), name: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
    }

    /// User-visible label for menu entries: "Wall A — 1500×844".
    public var displayLabel: String {
        return "\(name) — \(width)×\(height)"
    }
}

// MARK: - OutputSize

/// Per-job target output size.
///
/// Three cases:
///   - `.original`: no resize. The encoder receives source dims.
///   - `.preset(StandardResolution)`: dims come from the preset
///     table. Labelled, 4-pixel-legal by construction.
///   - `.custom(width:height:)`: user-entered dims. **Custom dims
///     are expected to be 4-pixel-aligned by the time they reach
///     the encoder.** This type does NOT silently round — that
///     enforcement happens at the Custom… sheet's commit step
///     (Phase F UI work). Callers that construct `.custom`
///     programmatically (e.g. tests, future code paths) are
///     responsible for the alignment.
///
/// Codable: derived synthesis handles the associated values via
/// keyed containers. JSON round-trip is the persistence path for
/// AppSettings (Phase C wiring) per RESIZE_PLAN.md §3.
public enum OutputSize: Hashable, Codable, Sendable {
    case original
    case preset(StandardResolution)
    case custom(width: Int, height: Int)

    /// Resolve to concrete `(width, height)` given the source
    /// dimensions. `.original` returns source dims; `.preset` and
    /// `.custom` return their stored dims.
    public func resolvedDimensions(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        switch self {
        case .original:
            return (sourceWidth, sourceHeight)
        case .preset(let preset):
            return preset.dimensions
        case .custom(let w, let h):
            return (w, h)
        }
    }
}
