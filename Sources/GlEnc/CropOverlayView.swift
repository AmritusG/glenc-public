// SPDX-License-Identifier: MIT
/*
 * CropOverlayView.swift — Crop Release Phase D.
 *
 * A leaf SwiftUI overlay that draws a crop rectangle on top of the
 * preview pane, with four corner drag handles for resize and
 * drag-anywhere-in-the-interior for translation (CROP_PLAN.md Q1
 * refined — no center handle, no edge-midpoint handles). Snapping to
 * the 4-pixel grid (L3) is live on every drag tick.
 *
 * This component is a LEAF: it consumes only a `CropAspectFit` and a
 * `Binding<CGRect?>` (source-space crop rect) plus an `isActive`
 * flag. It touches no EncodeQueue / AppSettings / EncodeJob /
 * PreviewArea — Phase E owns that wiring, the edit-mode state
 * machine, Apply/Cancel, and keyboard nudge. The component is
 * hostable from a SwiftUI preview with zero scaffolding (see the
 * #if DEBUG harness at the bottom of this file).
 *
 * Drag math lives in `CropDragMath` (pure functions, unit-tested) —
 * this view does the view↔source coordinate mapping via
 * `CropAspectFit` and never snaps or clamps itself.
 *
 * Test surface: headless tests cover CropDragMath. SwiftUI gestures,
 * @State binding, and visual layout are NOT headlessly testable —
 * the preview harness here and the human click-test (after Phase E
 * hosts this on the real PreviewArea) are the validating gates.
 */

import SwiftUI
import GlEncCore

struct CropOverlayView: View {

    /// View↔source coordinate mapping for the current preview layout.
    let aspectFit: CropAspectFit

    /// The crop rect in SOURCE-pixel space. `nil` = no crop set.
    @Binding var cropRectInSource: CGRect?

    /// Whether handles + drag gestures are live. When false the rect
    /// still renders (passive non-edit visualization — CROP_PLAN.md
    /// Q2 lean) but cannot be dragged.
    let isActive: Bool

    /// Codec-aware crop snap granularity (`OutputCodec.dimensionAlignment`):
    /// 1 = pixel-exact (ProRes/MJPEG/DXV/HAP — no snap), 2 = even
    /// (H.264/HEVC). Default 4 preserves the dev harness + tests.
    var alignment: Int = 4

    /// Crop Release Phase E — when true, the region OUTSIDE the crop
    /// rect (within the fitted preview area) is dimmed with a
    /// 55%-opacity black mask: the full source frame stays visible,
    /// the discarded context reads as darkened. This is the non-edit
    /// "what will encode, and its discarded surroundings"
    /// visualization for a selected, non-editing row that has a crop
    /// set (CROP_PLAN.md Q2). Default false — the active overlay and
    /// the Phase D preview harness leave it off; only Phase E's
    /// passive-mode call site sets it true.
    var showDimMask: Bool = false

    /// Crop Release Phase E.5 — when true, a faint outline of the
    /// source frame's fitted boundary is drawn in the preview pane,
    /// beneath the dim mask and crop stroke. Renders independently of
    /// crop state (it shows with no crop rect and no edit) — that is
    /// the point: a clip whose content is black to its edges gives no
    /// other cue where the source frame ends. Default false so the
    /// #if DEBUG preview harness and tests are unaffected; PreviewArea
    /// sets it from AppSettings.showClipBoundary.
    var showClipBoundary: Bool = false

    /// Crop Release Phase E.5 — when true (and `isActive`), the crop
    /// rect's stroke is drawn in the accent color instead of white,
    /// signalling that the preview pane holds keyboard focus and the
    /// arrow-key nudge is live. Replaces Phase E's full-rectangle
    /// focus border, which the click-test found too cluttered stacked
    /// with the clip-boundary lines and the crop rect. Default false.
    var isFocused: Bool = false

    /// Crop Release Phase E.10 — which corner handle currently holds
    /// keyboard-arrow focus, or nil if none is focused. When non-nil
    /// the matching handle renders 1.5× larger and accent-colored,
    /// and PreviewArea's arrow-key handler dispatches to
    /// `snappedResizeFromCorner` instead of the whole-rect translate.
    /// Set by each handle's drag onChanged (every tap or drag on a
    /// handle focuses it); cleared by background-tap on the overlay
    /// AND by EncodeQueue's endCropEdit teardown. Defaults to a
    /// constant nil binding so the `#if DEBUG` preview harness and
    /// existing call sites don't need to wire focus state.
    @Binding var focusedCorner: Corner?

    /// Source-space crop rect captured at the start of a drag.
    /// `DragGesture` reports translation cumulatively from drag-start,
    /// so every `.onChanged` tick applies that translation to the rect
    /// as it was when the drag began — applying to the live rect
    /// instead would compound the motion. `nil` when no drag is
    /// active.
    @State private var dragStartRect: CGRect?

    private let handleDiameter: CGFloat = 11
    private let handleHitDiameter: CGFloat = 24

    var body: some View {
        // Degenerate aspect-fit (no source loaded, or a zero view
        // rect during early layout) — draw nothing.
        if aspectFit.scale > 0 {
            ZStack(alignment: .topLeading) {
                // Deepest layer: the source-frame boundary outline.
                // Renders independently of crop state (Phase E.5) —
                // it must show even with no crop rect and no edit.
                if showClipBoundary {
                    clipBoundary()
                }
                // The crop rect, dim mask, and handles render only
                // when there is a rect to show — a committed crop, or
                // the active full-frame seed.
                if let sourceRect = displayedSourceRect {
                    let viewRect = aspectFit.viewRect(forSourceRect: sourceRect)
                    if showDimMask {
                        dimMask(cropViewRect: viewRect)
                    }
                    rectBody(viewRect: viewRect)
                    if isActive {
                        ForEach(Corner.allCases, id: \.self) { corner in
                            handleView(corner, viewRect: viewRect)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Phase E.10 — background tap (anywhere on the overlay
            // that is NOT a handle or the rect interior) clears the
            // focused corner. Inner gestures (handle drag, interior
            // drag — both DragGesture with minimumDistance: 0) claim
            // taps in their regions first, so the dim mask + clip
            // boundary + letterbox area are the only zones that fall
            // through to here. Matches the locked spec: background
            // tap clears, rect/handle tap does not.
            .contentShape(Rectangle())
            .onTapGesture {
                if isActive, focusedCorner != nil {
                    focusedCorner = nil
                }
            }
        }
    }

    /// The crop rect to render, in source space:
    ///   - the bound rect whenever one is set — rendered regardless of
    ///     `isActive` (passive non-edit visualization, CROP_PLAN.md Q2);
    ///   - when nil AND active, a seeded full-frame rect so the overlay
    ///     has geometry to display and to mutate on the first drag.
    ///     The full frame is the least-presumptuous starting point and
    ///     matches the user's mental model of "I haven't cropped
    ///     anything yet";
    ///   - when nil AND inactive, nil → `body` draws nothing.
    private var displayedSourceRect: CGRect? {
        if let r = cropRectInSource { return r }
        guard isActive else { return nil }
        return CropDragMath.fullFrameSeedRect(
            sourceWidth: aspectFit.sourceWidth,
            sourceHeight: aspectFit.sourceHeight,
            alignment: alignment)
    }

    // MARK: - Clip boundary (source-frame outline, all four sides)

    /// A faint 1pt closed outline of the source frame's fitted
    /// boundary in the preview pane (Crop Release Phase E.5 →
    /// Phase E.5.1 widened to all four sides — taller-than-clip
    /// window geometries letterbox top/bottom too, and those edges
    /// need the same visual cue as left/right). 30% white so the
    /// rectangle reads over letterbox bars and bright content
    /// alike. Never hit-testable; blocks neither the preview nor
    /// any crop gesture.
    private func clipBoundary() -> some View {
        let r = aspectFit.fittedViewRect
        return Rectangle()
            .strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }

    // MARK: - Dim mask (passive non-edit visualization)

    /// A 55%-opacity black fill over the fitted preview area with the
    /// crop rect punched out (even-odd fill — the outer rect fills,
    /// the inner crop rect cancels). Renders only in the passive
    /// non-edit visualization (`showDimMask`); never hit-testable, so
    /// it does not block the underlying preview or any gesture.
    private func dimMask(cropViewRect: CGRect) -> some View {
        Path { p in
            p.addRect(aspectFit.fittedViewRect)
            p.addRect(cropViewRect)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    // MARK: - Rect body (stroke + interior translation surface)

    /// Crop-rect stroke color: accent while the overlay is active and
    /// the preview pane has keyboard focus (the E.5 focus cue —
    /// arrow-key nudge is live), plain white otherwise.
    private var cropStrokeColor: Color {
        (isActive && isFocused) ? Color.accentColor : Color.white
    }

    private func rectBody(viewRect: CGRect) -> some View {
        ZStack {
            // Interior translation surface: a near-clear fill made
            // hit-testable by `contentShape`.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .contentShape(Rectangle())
            // Dark halo + stroke so the rect reads against arbitrary
            // preview content (bright or dark). The stroke is accent-
            // colored while the pane has keyboard focus (E.5 focus
            // cue), white otherwise.
            Rectangle().stroke(Color.black.opacity(0.55), lineWidth: 3)
            Rectangle().stroke(cropStrokeColor, lineWidth: 1.5)
        }
        .frame(width: viewRect.width, height: viewRect.height)
        .position(x: viewRect.midX, y: viewRect.midY)
        .gesture(interiorDragGesture)
    }

    // MARK: - Corner handles

    private func handleView(_ corner: Corner, viewRect: CGRect) -> some View {
        let p = cornerPoint(of: viewRect, corner)
        // Phase E.10 — focused handle renders 1.5× larger and
        // accent-colored. The Phase D drag gesture is unchanged;
        // tap-to-focus piggybacks on the drag's minimumDistance:0
        // onChanged firing once on any tap (see handleDragGesture).
        let isFocused = (focusedCorner == corner)
        let diameter = isFocused ? handleDiameter * 1.5 : handleDiameter
        return ZStack {
            Circle().fill(isFocused ? Color.accentColor : Color.white)
            Circle().stroke(Color.black.opacity(0.65), lineWidth: 1)
        }
        .frame(width: diameter, height: diameter)
        // Larger invisible hit area so the handle is easy to grab.
        .frame(width: handleHitDiameter, height: handleHitDiameter)
        .contentShape(Circle())
        .position(x: p.x, y: p.y)
        .gesture(handleDragGesture(corner))
    }

    // MARK: - Gestures

    /// Interior drag → translate the whole rect.
    private var interiorDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isActive, aspectFit.scale > 0 else { return }
                if dragStartRect == nil { dragStartRect = displayedSourceRect }
                guard let start = dragStartRect else { return }
                // View-space translation → source-space translation.
                let dxSource = value.translation.width / aspectFit.scale
                let dySource = value.translation.height / aspectFit.scale
                cropRectInSource = CropDragMath.snappedTranslatedRect(
                    original: start,
                    translationInSource: CGSize(width: dxSource, height: dySource),
                    sourceWidth: aspectFit.sourceWidth,
                    sourceHeight: aspectFit.sourceHeight,
                    alignment: alignment)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    /// Corner-handle drag → resize the rect, opposite corner fixed.
    /// Phase E.10: tap-to-focus piggybacks on the same gesture —
    /// `minimumDistance: 0` means even a pure tap fires `.onChanged`
    /// once, so setting `focusedCorner` here covers both clicks AND
    /// drags. Avoids the SwiftUI race between a separate
    /// `.onTapGesture` and this drag.
    private func handleDragGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isActive, aspectFit.scale > 0 else { return }
                // Phase E.10 — every tap or drag on a handle focuses
                // that corner. Idempotent on repeated drag ticks.
                if focusedCorner != corner { focusedCorner = corner }
                if dragStartRect == nil { dragStartRect = displayedSourceRect }
                guard let start = dragStartRect else { return }
                // The dragged corner's view-space point at drag-start,
                // plus the cumulative drag translation.
                let startViewRect = aspectFit.viewRect(forSourceRect: start)
                let startCorner = cornerPoint(of: startViewRect, corner)
                let newViewPoint = CGPoint(
                    x: startCorner.x + value.translation.width,
                    y: startCorner.y + value.translation.height)
                let newSourcePoint = aspectFit.sourcePoint(forViewPoint: newViewPoint)
                cropRectInSource = CropDragMath.snappedResizedRect(
                    original: start,
                    draggedCorner: corner,
                    newCornerSourcePoint: newSourcePoint,
                    sourceWidth: aspectFit.sourceWidth,
                    sourceHeight: aspectFit.sourceHeight,
                    alignment: alignment)
            }
            .onEnded { _ in dragStartRect = nil }
    }

    // MARK: - Helpers

    private func cornerPoint(of rect: CGRect, _ corner: Corner) -> CGPoint {
        switch corner {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

// MARK: - Preview harness (dev-only)

#if DEBUG
/// Click-test surface for CropOverlayView until Phase E hosts it on
/// the real PreviewArea. Fenced by `#if DEBUG` — never ships.
private struct CropOverlayPreviewHarness: View {
    @State private var crop: CGRect? =
        CGRect(x: 400, y: 200, width: 800, height: 600)
    @State private var active = true

    var body: some View {
        // Source 1920×1080 into an 800×450 view rect centered in an
        // 800×500 frame (vertical slack so a non-matching source
        // aspect would show letterbox bars).
        let viewRect = CGRect(x: 0, y: 25, width: 800, height: 450)
        let fit = CropAspectFit(sourceWidth: 1920, sourceHeight: 1080,
                                viewRect: viewRect)
        VStack(spacing: 12) {
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: viewRect.width, height: viewRect.height)
                    .position(x: viewRect.midX, y: viewRect.midY)
                CropOverlayView(aspectFit: fit,
                                cropRectInSource: $crop,
                                isActive: active,
                                focusedCorner: .constant(nil))
            }
            .frame(width: 800, height: 500)

            HStack(spacing: 16) {
                Toggle("Active", isOn: $active)
                Button("Reset to full") {
                    crop = CGRect(x: 0, y: 0, width: 1920, height: 1080)
                }
                Button("Clear (nil)") { crop = nil }
            }
            .padding(.bottom, 8)
        }
    }
}

#Preview("CropOverlayView") {
    CropOverlayPreviewHarness()
}
#endif
