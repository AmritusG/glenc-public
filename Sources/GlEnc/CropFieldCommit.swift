// SPDX-License-Identifier: MIT
/*
 * CropFieldCommit — Crop Release Phase E.9.
 *
 * Pure value-math behind the rowCrop edit-mode text fields. Takes a
 * typed value + which field + the in-flight crop rect + source dims,
 * returns the corrected value, the updated rect, and whether any
 * correction fired (drives the 300ms orange-flash UX cue).
 *
 * Three corrections, applied in this order:
 *   1. Minimum: W/H clamped to ≥ 4, X/Y clamped to ≥ 0. Catches
 *      typed "0", "-100", etc.
 *   2. Round-to-4: snap to the nearest 4-multiple, ties round up.
 *      Mirrors Phase D's `roundedToFourPixelMultiple` semantic
 *      (matches block-codec alignment requirements).
 *   3. Bounds clamp: keep the rect inside source. W ≤ sourceWidth -
 *      X, H ≤ sourceHeight - Y, X ≤ sourceWidth - W, Y ≤
 *      sourceHeight - H. Max is also 4-aligned via integer-truncate
 *      floor so the cropped rect itself is 4-aligned.
 *
 * `wasCorrected = true` iff the final corrected value differs from
 * the typed input. Single feedback mechanism for all three
 * corrections — the UI flashes orange regardless of which correction
 * fired, teaching "values snap to valid rect."
 *
 * The other three rect components are passed through untouched —
 * editing W never moves X/Y/H, etc.
 *
 * Phase E.9 spec rationale: every image/video editing tool the user
 * knows (Photoshop, Resolume, Premiere, AE, FCP, Resolve) has typable
 * numeric fields for crop position and dimensions; mouse-drag and
 * arrow-nudge alone cannot hit specific (X, Y, W, H) values without
 * trial-and-error. E.9 closes that gap.
 *
 * View-embedded math goes here, not in JobCardView — see the v0.9.4
 * Phase H Bug 5 standing rule.
 */

import Foundation
import CoreGraphics

/// Which of the four rect components is being committed.
/// Doubles as the @FocusState identifier in JobCardView for tab order.
public enum CropField: Hashable {
    case width, height, x, y
}

/// Outcome of a single field-commit operation.
public struct CropFieldCommitResult: Equatable {
    /// The full updated crop rect (the three non-edited components
    /// are byte-identical to `currentRect`'s).
    public let updatedRect: CGRect
    /// The final value placed on the edited field, post-correction.
    public let correctedValue: Int
    /// True iff `correctedValue != typedValue` — drives the
    /// 300ms orange-flash UX cue.
    public let wasCorrected: Bool
}

/// Commit a typed integer value onto one component of the in-flight
/// crop rect, applying minimum / round-to-4 / source-bounds clamp.
///
/// - Parameters:
///   - field: which component the user typed (W / H / X / Y).
///   - typedValue: the raw Int the user committed (Return or
///     focus-loss).
///   - currentRect: the in-flight `pendingCropRect` (in source-
///     pixel space).
///   - sourceWidth/sourceHeight: source clip dims in pixels. Pass
///     `Int.max` to disable bounds clamping (e.g. when dims are
///     not yet reachable to JobCardView — the documented fallback
///     during the brief window before PreviewArea reports dims).
/// - Returns: corrected value + updated rect + correction flag.
public func commitCropFieldValue(
    field: CropField,
    typedValue: Int,
    currentRect: CGRect,
    sourceWidth: Int,
    sourceHeight: Int,
    alignment: Int = 4
) -> CropFieldCommitResult {
    let a = max(1, alignment)
    let curX = Int(currentRect.minX.rounded())
    let curY = Int(currentRect.minY.rounded())
    let curW = Int(currentRect.width.rounded())
    let curH = Int(currentRect.height.rounded())

    let final: Int
    let updated: CGRect

    switch field {
    case .width:
        // Floor sourceWidth - curX to the codec alignment; min = alignment.
        let maxW = max(a, (sourceWidth - curX) / a * a)
        let snapped = roundToAlignMinDim(typedValue, a)
        final = min(snapped, maxW)
        updated = CGRect(x: CGFloat(curX), y: CGFloat(curY),
                         width: CGFloat(final),
                         height: CGFloat(curH))

    case .height:
        let maxH = max(a, (sourceHeight - curY) / a * a)
        let snapped = roundToAlignMinDim(typedValue, a)
        final = min(snapped, maxH)
        updated = CGRect(x: CGFloat(curX), y: CGFloat(curY),
                         width: CGFloat(curW),
                         height: CGFloat(final))

    case .x:
        // Floor (sourceWidth - curW) to the codec alignment; min 0.
        let maxX = max(0, (sourceWidth - curW) / a * a)
        let snapped = roundToAlignMin0(typedValue, a)
        final = min(snapped, maxX)
        updated = CGRect(x: CGFloat(final), y: CGFloat(curY),
                         width: CGFloat(curW),
                         height: CGFloat(curH))

    case .y:
        let maxY = max(0, (sourceHeight - curH) / a * a)
        let snapped = roundToAlignMin0(typedValue, a)
        final = min(snapped, maxY)
        updated = CGRect(x: CGFloat(curX), y: CGFloat(final),
                         width: CGFloat(curW),
                         height: CGFloat(curH))
    }

    return CropFieldCommitResult(
        updatedRect: updated,
        correctedValue: final,
        wasCorrected: final != typedValue)
}

/// Resolve the source dimensions a crop-field commit will clamp against,
/// from the (possibly-unpublished) preview dims.
///
/// Returns `nil` when EITHER axis is unknown. Fix-Brief A: the caller
/// MUST refuse the edit in that case rather than substitute `Int.max` —
/// passing `Int.max` to `commitCropFieldValue` disables the source-bounds
/// clamp (see the `sourceWidth`/`sourceHeight` parameter doc) and would
/// let a user commit a crop W/H larger than the frame. This pure seam
/// isolates that nil-vs-known decision so it is unit-testable; the
/// JobCardView caller does `guard let dims = cropClampSourceDims(...)
/// else { resync; return }`.
public func cropClampSourceDims(
    sourceWidth: Int?, sourceHeight: Int?
) -> (width: Int, height: Int)? {
    guard let w = sourceWidth, let h = sourceHeight else { return nil }
    return (w, h)
}

/// True iff a crop field's text changed since it gained focus — the
/// signal that a focus-loss represents a real user edit (commit) versus a
/// focus-in/out with no typing (must commit and seed NOTHING). Fix-Brief
/// A-2: a blur is only allowed to commit/seed when this returns true.
///
/// `baseline` is the field's string captured the moment it gained focus;
/// `current` is its string at focus-loss. A baseline comparison is used
/// rather than re-deriving "what sync would write" because
/// `syncCropFieldStringsFromPending` skips the focused field, so no fresh
/// canonical string exists for it while focused.
public func cropFieldDidEdit(current: String, baseline: String) -> Bool {
    return current != baseline
}

// MARK: - Round helpers (codec-aware: alignment 1 = no rounding)

/// Round to nearest `alignment`-multiple, min = alignment (W/H semantic).
/// `alignment == 1` → no rounding (returns `max(1, n)`).
private func roundToAlignMinDim(_ n: Int, _ alignment: Int) -> Int {
    let a = max(1, alignment)
    if a == 1 { return max(1, n) }
    if n <= 0 { return a }
    let rounded = ((n + a / 2) / a) * a
    return rounded < a ? a : rounded
}

/// Round to nearest `alignment`-multiple, min 0 (X/Y semantic).
/// `alignment == 1` → no rounding (returns `max(0, n)`).
private func roundToAlignMin0(_ n: Int, _ alignment: Int) -> Int {
    let a = max(1, alignment)
    if a == 1 { return max(0, n) }
    if n <= 0 { return 0 }
    return ((n + a / 2) / a) * a
}
