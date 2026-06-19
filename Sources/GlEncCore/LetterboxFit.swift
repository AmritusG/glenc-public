// SPDX-License-Identifier: MIT
/*
 * LetterboxFit.swift — Resize Release Phase G.
 *
 * Pure value math for letterbox/pillarbox fit. Given source dims and
 * target dims, returns the centered inner rect that preserves the
 * source aspect ratio and fits inside the target. The remainder of
 * the target is the bar area (top/bottom for letterbox, left/right
 * for pillarbox).
 *
 * Why this lives in its own file
 * ──────────────────────────────
 * The math is testable without any vImage / CVPixelBuffer / encoder
 * dependency. Phase F's `roundedToFourPixelMultiple` lived in a UI
 * file because the rounding only ever runs from the Custom sheet;
 * letterbox math runs on every non-original encode and benefits from
 * a focused test surface (16:9 into square, 9:16 into wide, etc.).
 *
 * 4-pixel alignment of the inner rect
 * ───────────────────────────────────
 * The encoder always receives the full TARGET dimensions (those are
 * already 4-aligned by L3 — presets + Custom sheet enforce it).
 * vImage can scale to any positive pixel count, but rounding the
 * inner rect's dimensions to a 4-multiple is preferred:
 *
 *   - It keeps the inner image with the same row-alignment
 *     characteristics the encoder normally sees on a non-letterboxed
 *     path. Block-based codecs (BC1/BC4) consume 4×4 pixel blocks; a
 *     non-4-aligned inner width means the rightmost block in the
 *     inner area straddles the bar boundary, which is fine but yields
 *     a slightly fuzzier edge transition.
 *   - It centers symmetrically when both target and inner are
 *     even-multiple. Asymmetric centering (e.g. one extra bar pixel
 *     on the right) is acceptable but uglier.
 *
 * Centering offsets (insetX / insetY) themselves are NOT required to
 * be 4-aligned — they're just the row start where the inner image
 * begins. Even-pixel offsets are nicer but not load-bearing.
 *
 * Matched-aspect fast path
 * ────────────────────────
 * When `srcW * dstH == srcH * dstW` (cross-multiply for exact
 * rational equality), the inner rect equals the target rect and no
 * bars exist. The caller's letterbox path should detect this and
 * delegate to a plain resize (no canvas fill, no inner-rect memcpy).
 *
 * Algorithm
 * ─────────
 *   - Cross-multiply to compare aspect ratios without float math
 *     (avoids precision drift on the equality check).
 *   - Source-wider: innerW = dstW, innerH = round-to-4(srcH * dstW / srcW).
 *   - Source-taller: innerH = dstH, innerW = round-to-4(srcW * dstH / srcH).
 *   - Center; clamp inner dims to never exceed target dims.
 */

import Foundation

// MARK: - Public API

/// A centered inner rect inside a target canvas, used for
/// letterbox/pillarbox compositing.
///
/// All four values are in target-canvas pixels. `insetX + width <=
/// canvasWidth` and `insetY + height <= canvasHeight` are
/// invariants — bars surround the rect on the axis where source
/// aspect doesn't match the target.
public struct LetterboxRect: Hashable, Sendable {
    public let insetX: Int
    public let insetY: Int
    public let width: Int
    public let height: Int

    public init(insetX: Int, insetY: Int, width: Int, height: Int) {
        self.insetX = insetX
        self.insetY = insetY
        self.width = width
        self.height = height
    }

    /// True when the inner rect covers the full target canvas — i.e.
    /// source aspect matched target aspect and no bars exist. Callers
    /// use this to take the no-bar fast path.
    public func fillsCanvas(canvasWidth: Int, canvasHeight: Int) -> Bool {
        return insetX == 0 && insetY == 0
            && width == canvasWidth && height == canvasHeight
    }
}

/// Compute the centered inner rect for letterbox compositing.
///
/// Returns a `LetterboxRect` whose width/height are 4-pixel-aligned
/// (rounded to the nearest 4-multiple, then clamped to never exceed
/// the target dims). The inset positions center the rect inside the
/// target.
///
/// Preconditions: all four dims must be positive. The caller is
/// responsible for that — this function does not validate (the
/// pipeline rejects non-positive dims upstream via L3).
///
/// Behavior:
///   - Source aspect == target aspect → inner rect equals target
///     (no bars). Caller may treat this as the no-bar fast path.
///   - Source wider than target → letterbox bars (top + bottom);
///     inner width = target width, inner height < target height.
///   - Source taller than target → pillarbox bars (left + right);
///     inner height = target height, inner width < target width.
public func letterboxRect(
    sourceWidth srcW: Int, sourceHeight srcH: Int,
    targetWidth dstW: Int, targetHeight dstH: Int
) -> LetterboxRect {
    // Cross-multiply for exact rational aspect comparison. Avoids
    // float-precision drift on the matched-aspect equality test.
    let srcAspectXdstH = srcW * dstH
    let srcHxdstW = srcH * dstW

    if srcAspectXdstH == srcHxdstW {
        // Matched aspect — inner rect fills the target.
        return LetterboxRect(insetX: 0, insetY: 0, width: dstW, height: dstH)
    }

    let innerW: Int
    let innerH: Int
    if srcAspectXdstH > srcHxdstW {
        // Source is wider → letterbox (top/bottom bars). Match the
        // target width and shrink the height proportionally.
        innerW = dstW
        let rawH = (srcH * dstW) / srcW
        innerH = clampToTarget(roundToFourMultiple(rawH), max: dstH)
    } else {
        // Source is taller → pillarbox (left/right bars). Match the
        // target height and shrink the width proportionally.
        innerH = dstH
        let rawW = (srcW * dstH) / srcH
        innerW = clampToTarget(roundToFourMultiple(rawW), max: dstW)
    }

    // Center inside the target. Bars take the remainder; their pixel
    // count is dstW-innerW (left+right) or dstH-innerH (top+bottom),
    // split as evenly as integer division allows. Asymmetric by at
    // most 1 pixel when the gap is odd.
    let insetX = (dstW - innerW) / 2
    let insetY = (dstH - innerH) / 2

    return LetterboxRect(insetX: insetX, insetY: insetY,
                          width: innerW, height: innerH)
}

// MARK: - Helpers

/// Round `n` to the nearest multiple of 4 using round-half-up
/// (matches Phase F's `roundedToFourPixelMultiple` semantics for
/// positive integers). Returns 4 for n < 4 (the smallest legal
/// 4-multiple); the caller must clamp upward as needed.
///
/// This is a separate helper rather than a call into the Phase F UI
/// file because GlEncCore must not depend on the GlEnc executable
/// target.
internal func roundToFourMultiple(_ n: Int) -> Int {
    if n <= 0 { return 4 }
    let rounded = ((n + 2) / 4) * 4
    return rounded < 4 ? 4 : rounded
}

/// Clamp `value` to never exceed `max`. Used to guard the rare
/// case where round-up pushes the inner dim 1-3 pixels past the
/// target — we'd rather lose a row than overflow into the bar area.
internal func clampToTarget(_ value: Int, max: Int) -> Int {
    return value > max ? max : value
}
