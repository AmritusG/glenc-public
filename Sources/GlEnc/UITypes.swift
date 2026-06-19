// SPDX-License-Identifier: MIT
/*
 * UITypes.swift — Phase 7A + v0.9.1 Phase G + v0.9.3 Phase C.
 *
 * Two-dropdown UI (Codec × Alpha) per planner decision: simpler menu
 * for the typical VJ workflow than a single dropdown over seven
 * cryptic codec names. The library still speaks `DXVFormat`
 * internally; these enums are the user-facing translation layer.
 *
 * Codec × Alpha matrix (v0.9.3):
 *
 *      DXV3 Normal × No alpha   → DXT1   (v0.2)
 *      DXV3 Normal × With alpha → DXT5   (v0.3)
 *      DXV3 HQ     × No alpha   → YCG6   (v0.4)
 *      DXV3 HQ     × With alpha → YG10   (v0.5)
 *      HAP         × No alpha   → Hap1   (v0.9.1)
 *      HAP         × With alpha → Hap5   (v0.9.1)
 *      HAP Q       × No alpha   → HapY   (v0.9.1)
 *      HAP Q       × With alpha → HapM   (v0.9.3 Phase C)
 *
 * Phase C wired HapM into the dispatch chain: DXVFormat.hapM exists,
 * HapFrameEncoder.Codec.hapM dispatches to a HapY + HapA composition
 * under an outer 0x0D section, and the (.hapQ, .withAlpha) resolver
 * below now produces .hapM. The JobCardView disable gate that hid
 * the combination through v0.9.2 is removed in Phase D, not here —
 * HapM is fully functional in code at Phase C but still UI-
 * unreachable until Phase D flips the gate.
 *
 * HapA (standalone RGTC1/BC4 alpha-only) exists as DXVFormat.hapA
 * and as a fully-shipped encoder but is NOT exposed as a user-facing
 * Codec dropdown entry. v0.9.2 Phase F validation found Resolume
 * Arena doesn't import standalone HapA as a clip codec (it loads
 * Hap1/Hap5/HapY/HapM only); shipping a UI entry that silently
 * fails in users' primary target app would be worse than not
 * offering it. The encoder remains intact as HapM's BC4 building
 * block.
 *
 * Reuses `DXVFormat.hasAlpha` from the library; adds the inverse
 * `DXVFormat(tier:alpha:)` plus `qualityTier` / `alphaMode` accessors
 * typed as the UI enums for symmetric two-way bindings in SwiftUI.
 */

import Foundation
import GlEncCore

/// Codec dropdown — first half of the codec UI. Renamed concept-wise
/// from "Quality" (DXV3-only) to "Codec" in v0.9.1, but the type name
/// stays `QualityTier` to avoid a high-churn rename across persistence
/// keys, AppSettings, EncodeQueue, etc.
enum QualityTier: String, CaseIterable, Identifiable, Hashable {
    case normal
    case hq
    case hap
    case hapQ = "hap_q"

    var id: String { rawValue }

    /// User-visible dropdown label.
    var label: String {
        switch self {
        case .normal: return "DXV3 Normal"
        case .hq:     return "DXV3 HQ"
        case .hap:    return "HAP"
        case .hapQ:   return "HAP Q"
        }
    }
}

/// Alpha-presence dropdown — second half of the codec UI.
enum AlphaMode: String, CaseIterable, Identifiable, Hashable {
    case withoutAlpha = "no_alpha"
    case withAlpha    = "with_alpha"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .withoutAlpha: return "No alpha"
        case .withAlpha:    return "With alpha"
        }
    }
}

extension DXVFormat {
    /// Compose a `DXVFormat` from the two UI-side enums. Total
    /// mapping across all 8 combinations.
    ///
    /// v0.9.3 Phase C: `(.hapQ, .withAlpha)` now resolves to `.hapM`
    /// (the Resolume-loadable HAP+alpha variant — outer 0x0D wrapping
    /// HapY + HapA inner sections). Replaces v0.9.2's `.hapY` stub
    /// fallback. Q3 + Q4 locked: the swap is UNCONDITIONAL — no
    /// opaque-source branch, no defensive fallback. Opaque content
    /// encodes as HapM exactly like transparent content; HapFrameEncoder
    /// (.hapM) emits an opaque alpha section for opaque sources.
    init(tier: QualityTier, alpha: AlphaMode) {
        switch (tier, alpha) {
        case (.normal, .withoutAlpha): self = .dxt1
        case (.normal, .withAlpha):    self = .dxt5
        case (.hq,     .withoutAlpha): self = .ycg6
        case (.hq,     .withAlpha):    self = .yg10
        case (.hap,    .withoutAlpha): self = .hap1
        case (.hap,    .withAlpha):    self = .hap5
        case (.hapQ,   .withoutAlpha): self = .hapY
        case (.hapQ,   .withAlpha):    self = .hapM
        }
    }

    /// Decompose to the UI-side codec.
    ///
    /// `.hapA` has no dedicated UI tier — standalone HapA is not
    /// exposed in the user-facing Codec dropdown (Resolume doesn't
    /// import the variant; v0.9.2 Phase F finding). The encoder is
    /// fully retained (DXVFormat.hapA, HapAEncoder, HapFrameEncoder.
    /// Codec.hapA) as HapM's BC4 building block. If a `.hapA` job
    /// somehow appears in the queue (programmatic construction,
    /// future code paths), the UI shows "HAP" as the closest tier —
    /// the user can't reach this state via the dropdown.
    /// `.hapM` resolves to the HAP Q tier (HAP Q + alpha = HapM).
    var qualityTier: QualityTier {
        switch self {
        case .dxt1, .dxt5: return .normal
        case .ycg6, .yg10: return .hq
        case .hap1, .hap5: return .hap
        case .hapY, .hapM: return .hapQ
        case .hapA:        return .hap  // no dedicated UI tier
        }
    }

    /// Decompose to the UI-side alpha mode. Mirror of `.hasAlpha`
    /// typed as `AlphaMode` for symmetric two-way bindings.
    /// `.hapA` and `.hapM` map to `.withAlpha` since both carry alpha
    /// by definition.
    var alphaMode: AlphaMode {
        switch self {
        case .dxt1, .ycg6, .hap1, .hapY:        return .withoutAlpha
        case .dxt5, .yg10, .hap5, .hapA, .hapM: return .withAlpha
        }
    }
}
