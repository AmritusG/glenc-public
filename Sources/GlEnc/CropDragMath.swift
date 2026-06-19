// SPDX-License-Identifier: MIT
/*
 * CropDragMath.swift — Crop Release Phase D.
 *
 * Pure-function drag math for the crop overlay, extracted from
 * `CropOverlayView`'s body so it is unit-testable headlessly (the
 * v0.9.4 Phase H "Bug 5" lesson — view-embedded logic is invisible
 * to the test suite; factor it out).
 *
 * Coordinate space
 * ────────────────
 * Every parameter and return value of every function here is in
 * SOURCE-PIXEL space (CGFloat values naming integer source pixels),
 * top-left origin (CROP_PLAN.md Q2). The overlay maps view-space
 * drag deltas into source space via `CropAspectFit` BEFORE calling
 * into this file; nothing here touches view points.
 *
 * 4-pixel snapping (CROP_PLAN.md L3, §4g)
 * ───────────────────────────────────────
 * Snapping uses `roundedToFourPixelMultiple` — the GlEnc-target free
 * function in `ResizeCustomSheet.swift`. Per §4g there is exactly one
 * GlEnc-target copy and CropDragMath calls it; no third copy.
 *
 * One caveat the §4g instruction did not anticipate:
 * `roundedToFourPixelMultiple` FLOORS its result at 4 — it was built
 * for DIMENSIONS, where 4 is the minimum legal crop size. A crop-rect
 * COORDINATE, however, legitimately includes 0 (the top/left edge of
 * the source). So coordinate snapping goes through `snapCoordinate`,
 * a thin wrapper that delegates to `roundedToFourPixelMultiple` for
 * values ≥ 2 and returns 0 for values ≤ 1 (and for negatives — a
 * corner dragged off the source). This is a wrapper, not a
 * reimplementation: the round-to-nearest-4 arithmetic still lives
 * solely in `roundedToFourPixelMultiple`.
 */

import Foundation
import CoreGraphics

/// Which corner of a crop rect a resize drag is moving. The diagonally
/// opposite corner stays fixed for the duration of the drag. Passed by
/// `CropOverlayView`'s per-handle drag gestures into
/// `CropDragMath.snappedResizedRect`.
enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// Namespace for the crop overlay's pure drag math. All inputs and
/// outputs are source-pixel-space (top-left origin).
enum CropDragMath {

    // MARK: - Resize (one corner moves, the opposite stays fixed)

    /// Recompute a crop rect when one corner is dragged.
    ///
    /// - Parameters:
    ///   - original: the crop rect before this drag tick, source space.
    ///   - draggedCorner: which corner the gesture is moving.
    ///   - newCornerSourcePoint: the dragged corner's new position,
    ///     already mapped into source space by the caller. Need not be
    ///     4-pixel-aligned — this function snaps it.
    ///   - sourceWidth/sourceHeight: source clip dimensions in pixels.
    ///
    /// Behavior:
    ///   - The dragged corner snaps to the nearest 4-pixel multiple,
    ///     then clamps into `[0, alignedMax]` on each axis.
    ///   - The diagonally opposite corner is held fixed (its source
    ///     coordinates are unchanged). Because both that corner and
    ///     the snapped dragged corner are 4-multiples, the resulting
    ///     width and height are 4-multiples for free.
    ///   - A 4-pixel floor is enforced: dragging a corner onto or past
    ///     the opposite corner collapses the rect to 4×4 at the
    ///     boundary rather than inverting or producing a negative
    ///     dimension.
    ///
    /// Precondition (not validated): `original`'s opposite corner is
    /// already 4-pixel-aligned — true for any rect produced by this
    /// file or by `fullFrameSeedRect`.
    static func snappedResizedRect(
        original: CGRect,
        draggedCorner: Corner,
        newCornerSourcePoint: CGPoint,
        sourceWidth: Int,
        sourceHeight: Int,
        alignment: Int = 4
    ) -> CGRect {
        let a = max(1, alignment)
        let maxX = alignedMax(sourceWidth, alignment: a)
        let maxY = alignedMax(sourceHeight, alignment: a)

        // The diagonally opposite corner — held fixed.
        let fixedX: CGFloat
        let fixedY: CGFloat
        switch draggedCorner {
        case .topLeft:     fixedX = original.maxX; fixedY = original.maxY
        case .topRight:    fixedX = original.minX; fixedY = original.maxY
        case .bottomLeft:  fixedX = original.maxX; fixedY = original.minY
        case .bottomRight: fixedX = original.minX; fixedY = original.minY
        }

        // Snap the dragged corner, then clamp into source bounds.
        let snappedX = min(maxX, max(0, snapCoordinate(newCornerSourcePoint.x, alignment: a)))
        let snappedY = min(maxY, max(0, snapCoordinate(newCornerSourcePoint.y, alignment: a)))

        // Resolve the X extent. A left-edge corner stays ≥ 4 px left
        // of the fixed corner; a right-edge corner stays ≥ 4 px right.
        // Dragging past the fixed corner collapses to the 4-px floor.
        let isLeftCorner = (draggedCorner == .topLeft || draggedCorner == .bottomLeft)
        let originX: CGFloat
        let width: CGFloat
        if isLeftCorner {
            let x = max(0, min(snappedX, fixedX - CGFloat(a)))
            originX = x
            width = fixedX - x
        } else {
            let x = min(maxX, max(snappedX, fixedX + CGFloat(a)))
            originX = fixedX
            width = x - fixedX
        }

        // Same for the Y extent.
        let isTopCorner = (draggedCorner == .topLeft || draggedCorner == .topRight)
        let originY: CGFloat
        let height: CGFloat
        if isTopCorner {
            let y = max(0, min(snappedY, fixedY - CGFloat(a)))
            originY = y
            height = fixedY - y
        } else {
            let y = min(maxY, max(snappedY, fixedY + CGFloat(a)))
            originY = fixedY
            height = y - fixedY
        }

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    // MARK: - Arrow-key corner resize (Phase E.10)

    /// Resize a crop rect by moving one corner via a fixed delta
    /// (arrow-key step in source pixels), opposite corner pinned.
    ///
    /// Thin wrapper around `snappedResizedRect` — it derives the
    /// dragged corner's new source-pixel point from the current
    /// rect + delta and delegates. All snap / clamp / 4-px-from-
    /// opposite floor behavior is inherited from `snappedResizedRect`,
    /// so arrow-resize is byte-equivalent to a drag that landed on
    /// the same target point.
    ///
    /// - Parameters:
    ///   - rect: the crop rect before this step, source space.
    ///   - corner: which corner the arrow is moving.
    ///   - delta: the step in source pixels (e.g. (-4, 0) for one
    ///     left-arrow press). Need not be 4-pixel-aligned; the
    ///     wrapper's snap handles it.
    ///   - sourceWidth/sourceHeight: source clip dimensions in
    ///     pixels.
    static func snappedResizeFromCorner(
        rect: CGRect,
        corner: Corner,
        delta: CGVector,
        sourceWidth: Int,
        sourceHeight: Int,
        alignment: Int = 4
    ) -> CGRect {
        let cornerPoint: CGPoint
        switch corner {
        case .topLeft:     cornerPoint = CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    cornerPoint = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  cornerPoint = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: cornerPoint = CGPoint(x: rect.maxX, y: rect.maxY)
        }
        let newPoint = CGPoint(
            x: cornerPoint.x + delta.dx,
            y: cornerPoint.y + delta.dy)
        return snappedResizedRect(
            original: rect,
            draggedCorner: corner,
            newCornerSourcePoint: newPoint,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            alignment: alignment)
    }

    // MARK: - Translate (whole rect moves, size unchanged)

    /// Recompute a crop rect when its interior is dragged.
    ///
    /// - Parameters:
    ///   - original: the crop rect before this drag tick, source space.
    ///   - translationInSource: the drag delta, mapped into source
    ///     pixels by the caller. Need not be 4-pixel-aligned.
    ///   - sourceWidth/sourceHeight: source clip dimensions in pixels.
    ///
    /// Behavior: the rect's origin moves by `translationInSource`, the
    /// new origin snaps to the nearest 4-pixel multiple, and the rect
    /// is clamped so it stays fully inside `[0, alignedMax]`. Width and
    /// height are returned unchanged (they were already 4-aligned).
    static func snappedTranslatedRect(
        original: CGRect,
        translationInSource: CGSize,
        sourceWidth: Int,
        sourceHeight: Int,
        alignment: Int = 4
    ) -> CGRect {
        let width = original.width
        let height = original.height
        let maxX = alignedMax(sourceWidth, alignment: alignment)
        let maxY = alignedMax(sourceHeight, alignment: alignment)

        let snappedX = snapCoordinate(original.minX + translationInSource.width, alignment: alignment)
        let snappedY = snapCoordinate(original.minY + translationInSource.height, alignment: alignment)

        // Clamp so the whole rect stays inside the source; size fixed.
        let clampedX = max(0, min(snappedX, maxX - width))
        let clampedY = max(0, min(snappedY, maxY - height))

        return CGRect(x: clampedX, y: clampedY, width: width, height: height)
    }

    // MARK: - Seed

    /// The default crop rect for a source with no crop yet: the whole
    /// source frame, snapped to the 4-pixel grid. Each dimension is
    /// rounded DOWN to a 4-multiple (`alignedMax`) — never up, which
    /// would exceed the source. For a 4-pixel-aligned source (all
    /// presets, the common case) this is exactly
    /// `(0, 0, sourceWidth, sourceHeight)`.
    ///
    /// `CropOverlayView` uses this to seed geometry when the bound
    /// crop rect is nil and the overlay is active.
    static func fullFrameSeedRect(sourceWidth: Int, sourceHeight: Int, alignment: Int = 4) -> CGRect {
        return CGRect(x: 0, y: 0,
                      width: alignedMax(sourceWidth, alignment: alignment),
                      height: alignedMax(sourceHeight, alignment: alignment))
    }

    // MARK: - Helpers

    /// Snap a source-pixel coordinate to the nearest multiple of 4,
    /// allowing 0. Delegates to `roundedToFourPixelMultiple` for
    /// values ≥ 2; returns 0 for values ≤ 1 (including negatives)
    /// because the rounder floors its result at 4 — correct for
    /// dimensions, wrong for a coordinate, whose top/left edge is 0.
    private static func snapCoordinate(_ c: CGFloat, alignment: Int = 4) -> CGFloat {
        let n = Int(c.rounded())
        let a = max(1, alignment)
        if a == 1 { return CGFloat(max(0, n)) }   // pixel-exact, no snap
        if n <= 1 { return 0 }
        return CGFloat(roundedToMultiple(n, of: a))
    }

    /// Largest 4-pixel-aligned coordinate not exceeding `dim` — the
    /// rightmost / bottommost edge a crop rect may reach. For a source
    /// whose dimension is itself 4-aligned this equals `dim`; for an
    /// odd source it rounds down (CROP_RESIZE_PLAN.md §4 — the lost
    /// 1–3 px column/row would not render in Resolume anyway).
    private static func alignedMax(_ dim: Int, alignment: Int = 4) -> CGFloat {
        let a = max(1, alignment)
        return CGFloat(max(0, (dim / a) * a))
    }
}
