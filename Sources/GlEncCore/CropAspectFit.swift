// SPDX-License-Identifier: MIT
/*
 * CropAspectFit.swift — Crop Release Phase C.
 *
 * Pure-value math mapping between two coordinate spaces:
 *
 *   - VIEW space   — SwiftUI points inside the preview pane's rect.
 *   - SOURCE space — pixels of the source clip. CGFloat-typed, but
 *                    every value names an integer source pixel.
 *
 * Why this type exists
 * ────────────────────
 * The preview pane aspect-fits the source clip into its bounds and
 * letterboxes the remainder. Per CROP_PLAN.md §4a that aspect-fit
 * math currently lives, un-reused, inside `PreviewVideoLayer.draw`'s
 * GL viewport pass. The Crop overlay (Phase D) needs the same math in
 * a form it can drive drag gestures with and that a unit test can
 * exercise without an encode or a live CALayer. CROP_PLAN.md Q6 locks
 * the decision to extract it into this leaf helper rather than reach
 * into `PreviewPlayerModel`.
 *
 * Relationship to LetterboxFit
 * ────────────────────────────
 * `LetterboxFit` is the STRUCTURAL sibling — same "pure math in its
 * own file, testable without an encode" shape — but NOT a drop-in.
 * `LetterboxFit` computes letterbox-bar dimensions in encoder-pixel
 * space for the resize stage; `CropAspectFit` does view↔source
 * coordinate mapping for the interactive overlay. Different operation,
 * different consumer.
 *
 * Origin convention
 * ─────────────────
 * Top-left everywhere (CROP_PLAN.md Q2). A view point at the top edge
 * of the fitted area (`fittedViewRect.minY`) maps to source `y = 0`,
 * the top row of source pixels — matching `CVPixelBuffer` row
 * indexing and the encoder's BGRA byte layout. There is NO coordinate
 * flip anywhere in this type.
 *
 * Snapping is NOT this type's job
 * ───────────────────────────────
 * The four mapping methods are pure CGFloat-in / CGFloat-out and do
 * not round. Snapping a dragged crop rect to the 4-pixel grid (L3) is
 * the overlay's responsibility (Phase D), applied AFTER mapping into
 * source space, via the existing per-target 4-px rounders
 * (CROP_PLAN.md §4g).
 */

import Foundation
import CoreGraphics

/// Maps points and rects between preview-view space and source-pixel
/// space for a single (source dims, view rect) pairing.
///
/// Construct one per layout pass; `fittedViewRect` and `scale` are
/// resolved once at init and the mapping methods are O(1) reads.
///
/// Degenerate inputs — a non-positive source dimension or an empty
/// view rect — yield `fittedViewRect == .zero` and `scale == 0`, and
/// the source-producing methods return `.zero`. This is deliberate
/// (not a precondition trap): `PreviewPlayerModel.sourceWidth/Height`
/// are `0` until a clip loads, and SwiftUI's `GeometryReader` reports
/// `.zero` before its first layout — both are normal transient states
/// the overlay passes through, and trapping on them would crash the
/// app during ordinary startup. A zero result renders as nothing,
/// which is the correct overlay behavior for "no source yet."
public struct CropAspectFit: Hashable, Sendable {

    /// Source clip dimensions, in source pixels.
    public let sourceWidth: Int
    public let sourceHeight: Int

    /// The preview pane's rect, in view points.
    public let viewRect: CGRect

    /// The sub-rect of `viewRect` where source content actually
    /// displays after aspect-fit, in view points. Equals `viewRect`
    /// when source aspect == view aspect; otherwise it is centered
    /// inside `viewRect` with letterbox bars on the mismatched axis
    /// (vertical bars left/right for a narrow source in a wide view,
    /// horizontal bars top/bottom for a wide source in a tall view).
    /// `.zero` for degenerate inputs.
    public let fittedViewRect: CGRect

    /// Uniform scale factor: view points per source pixel. One number
    /// — aspect is preserved, so the X and Y scales are equal. `0`
    /// for degenerate inputs.
    public let scale: CGFloat

    /// Capture the mapping context for one source clip displayed in
    /// one preview view rect.
    ///
    /// - Parameters:
    ///   - sourceWidth:  source clip width in pixels.
    ///   - sourceHeight: source clip height in pixels.
    ///   - viewRect:     the preview pane's rect, in view points.
    public init(sourceWidth: Int, sourceHeight: Int, viewRect: CGRect) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.viewRect = viewRect

        // Degenerate guard — non-positive source dims or an empty
        // view rect. Yield a zero fit rather than dividing by zero.
        guard sourceWidth > 0, sourceHeight > 0,
              viewRect.width > 0, viewRect.height > 0 else {
            self.fittedViewRect = .zero
            self.scale = 0
            return
        }

        let srcW = CGFloat(sourceWidth)
        let srcH = CGFloat(sourceHeight)
        let sourceAspect = srcW / srcH
        let viewAspect = viewRect.width / viewRect.height

        let fittedW: CGFloat
        let fittedH: CGFloat
        if viewAspect > sourceAspect {
            // View is wider than the source aspect → vertical bars
            // left and right; fitted height fills the view.
            fittedH = viewRect.height
            fittedW = viewRect.height * sourceAspect
        } else {
            // View is taller than (or equal to) the source aspect →
            // horizontal bars top and bottom; fitted width fills the
            // view. The equal case produces fitted == view (no bars).
            fittedW = viewRect.width
            fittedH = viewRect.width / sourceAspect
        }

        // Center the fitted rect inside the view. Top-left origin:
        // minX/minY are the left/top edges of the displayed content.
        let fittedX = viewRect.minX + (viewRect.width - fittedW) / 2
        let fittedY = viewRect.minY + (viewRect.height - fittedH) / 2

        self.fittedViewRect = CGRect(x: fittedX, y: fittedY,
                                     width: fittedW, height: fittedH)
        self.scale = fittedW / srcW
    }

    // MARK: - Point mapping

    /// View-space point → source-pixel-space point.
    ///
    /// A point at `fittedViewRect.origin` (the top-left of the
    /// displayed content) maps to source `(0, 0)`. The mapping is
    /// linear and UNCLAMPED: a view point inside a letterbox bar (or
    /// otherwise outside `fittedViewRect`) maps to a source point with
    /// a negative component or a component ≥ the source dimension.
    /// Clamping to `[0, sourceW] × [0, sourceH]` is the caller's job.
    ///
    /// Returns `.zero` for degenerate inputs (`scale == 0`).
    public func sourcePoint(forViewPoint viewPoint: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        return CGPoint(
            x: (viewPoint.x - fittedViewRect.minX) / scale,
            y: (viewPoint.y - fittedViewRect.minY) / scale)
    }

    /// Source-pixel-space point → view-space point.
    ///
    /// Source `(0, 0)` maps to `fittedViewRect.origin`. The inverse of
    /// `sourcePoint(forViewPoint:)`.
    ///
    /// Returns `.zero` for degenerate inputs (`scale == 0`).
    public func viewPoint(forSourcePoint sourcePoint: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        return CGPoint(
            x: fittedViewRect.minX + sourcePoint.x * scale,
            y: fittedViewRect.minY + sourcePoint.y * scale)
    }

    // MARK: - Rect mapping

    /// View-space rect → source-pixel-space rect.
    ///
    /// Origin maps via `sourcePoint(forViewPoint:)`; width and height
    /// divide by `scale`. Unclamped, like the point mapping.
    ///
    /// Returns `.zero` for degenerate inputs (`scale == 0`).
    public func sourceRect(forViewRect viewRect: CGRect) -> CGRect {
        guard scale > 0 else { return .zero }
        let origin = sourcePoint(forViewPoint: viewRect.origin)
        return CGRect(x: origin.x, y: origin.y,
                      width: viewRect.width / scale,
                      height: viewRect.height / scale)
    }

    /// Source-pixel-space rect → view-space rect.
    ///
    /// Origin maps via `viewPoint(forSourcePoint:)`; width and height
    /// multiply by `scale`. The inverse of `sourceRect(forViewRect:)`.
    ///
    /// Returns `.zero` for degenerate inputs (`scale == 0`).
    public func viewRect(forSourceRect sourceRect: CGRect) -> CGRect {
        guard scale > 0 else { return .zero }
        let origin = viewPoint(forSourcePoint: sourceRect.origin)
        return CGRect(x: origin.x, y: origin.y,
                      width: sourceRect.width * scale,
                      height: sourceRect.height * scale)
    }
}
