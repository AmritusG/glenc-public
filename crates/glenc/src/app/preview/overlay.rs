//! The crop overlay (Swift `CropOverlayView.swift`): the source-frame outline (`showClipBoundary`), the dim mask
//! outside a committed crop, the crop rectangle, and — during a crop edit — four corner handles (11 pt, 24-pt hit
//! circles; the focused one 1.5× and accent) and the interior drag that moves the whole rectangle. The math is
//! [`super::crop`]'s; this file only maps points and draws.

use super::crop::{self, AspectFit, Corner, Rect};
use crate::app::look;
use egui::{Color32, Painter, Pos2, Stroke, StrokeKind, pos2, vec2};

const HANDLE: f32 = 11.0;
const HANDLE_HIT: f32 = 24.0;

/// What the overlay shows this frame.
pub struct Input {
    pub fit: AspectFit,
    /// The crop rectangle to draw, source pixels (`displayedSourceRect`: the bound rect, else the full-frame seed
    /// while editing, else none).
    pub rect: Option<Rect>,
    /// Handles and drags are live (`isActive`: this row is in a crop edit).
    pub active: bool,
    /// The passive dim mask (`showDimMask`: a committed crop, no edit anywhere).
    pub dim: bool,
    /// The faint source-frame outline (`showClipBoundary`, Preferences).
    pub boundary: bool,
    /// The pane holds keyboard focus (`isFocused`): the rectangle's stroke turns accent.
    pub focused: bool,
    /// The output codec's snap (`dimensionAlignment`).
    pub alignment: i64,
}

enum Grab {
    Interior,
    Corner(Corner),
}

struct Drag {
    grab: Grab,
    /// `dragStartRect`: drags apply their whole translation to the rect as it was when they began.
    start: Rect,
    origin: Pos2,
}

/// The overlay's own state: the drag in flight and the focused corner (`queue.focusedCropCorner`).
#[derive(Default)]
pub struct Overlay {
    pub focused_corner: Option<Corner>,
    drag: Option<Drag>,
}

fn to_egui(r: Rect) -> egui::Rect {
    egui::Rect::from_min_size(pos2(r.x as f32, r.y as f32), vec2(r.w as f32, r.h as f32))
}

fn point(p: Pos2) -> (f64, f64) {
    (f64::from(p.x), f64::from(p.y))
}

impl Overlay {
    /// The edit ended or moved to another row (`endCropEdit` clears the focused corner).
    pub fn reset(&mut self) {
        self.focused_corner = None;
        self.drag = None;
    }

    /// Draw over the preview area and handle its pointer; returns the new pending crop when a drag moved it.
    pub fn show(&mut self, ui: &egui::Ui, area: &egui::Response, input: &Input) -> Option<Rect> {
        let fit = &input.fit;
        if fit.scale <= 0.0 {
            self.drag = None;
            return None;
        }
        let painter = ui.painter_at(area.rect);
        if input.boundary {
            // 1 pt, 30 % white, inside the fitted picture (`clipBoundary`, `:175-182`).
            painter.rect_stroke(to_egui(fit.fitted), 0.0, Stroke::new(1.0, Color32::from_white_alpha(77)), StrokeKind::Inside);
        }
        let mut changed = None;
        if let Some(source_rect) = input.rect {
            let view = fit.view_rect(source_rect);
            if input.dim {
                dim_mask(&painter, to_egui(fit.fitted), to_egui(view));
            }
            // Dark halo + stroke so the rect reads on any picture (`rectBody`, `:209-226`).
            let r = to_egui(view);
            painter.rect_stroke(r, 0.0, Stroke::new(3.0, Color32::from_black_alpha(140)), StrokeKind::Middle);
            let color = if input.active && input.focused { look::ACCENT } else { Color32::WHITE };
            painter.rect_stroke(r, 0.0, Stroke::new(1.5, color), StrokeKind::Middle);
            if input.active {
                for c in Corner::ALL {
                    let (x, y) = view.corner(c);
                    let focused = self.focused_corner == Some(c);
                    let d = if focused { HANDLE * 1.5 } else { HANDLE };
                    let center = pos2(x as f32, y as f32);
                    painter.circle_filled(center, d / 2.0, if focused { look::ACCENT } else { Color32::WHITE });
                    painter.circle_stroke(center, d / 2.0, Stroke::new(1.0, Color32::from_black_alpha(166)));
                }
                changed = self.pointer(ui, area, input, view, source_rect);
            }
        }
        if !input.active {
            self.drag = None;
        }
        changed
    }

    fn pointer(&mut self, ui: &egui::Ui, area: &egui::Response, input: &Input, view: Rect, source_rect: Rect) -> Option<Rect> {
        let (pressed, down, origin, at) =
            ui.input(|i| (i.pointer.primary_pressed(), i.pointer.primary_down(), i.pointer.press_origin(), i.pointer.interact_pos()));
        if pressed
            && let Some(o) = origin
            && area.rect.contains(o)
            && area.contains_pointer()
        {
            // Hit order: the handles (the last drawn on top), then the interior; elsewhere a tap clears the focused
            // corner (`.onTapGesture`, `:138-143`).
            let corner = Corner::ALL.into_iter().rev().find(|c| {
                let (x, y) = view.corner(*c);
                o.distance(pos2(x as f32, y as f32)) <= HANDLE_HIT / 2.0
            });
            let grab = match corner {
                Some(c) => {
                    // Every tap or drag on a handle focuses it (`:278-284`).
                    self.focused_corner = Some(c);
                    Some(Grab::Corner(c))
                }
                None if view.contains(point(o)) => Some(Grab::Interior),
                None => {
                    self.focused_corner = None;
                    None
                }
            };
            self.drag = grab.map(|grab| Drag { grab, start: source_rect, origin: o });
        }
        if !down {
            self.drag = None;
            return None;
        }
        let (drag, at) = (self.drag.as_ref()?, at?);
        let fit = &input.fit;
        let (dx, dy) = (f64::from(at.x - drag.origin.x), f64::from(at.y - drag.origin.y));
        let next = match drag.grab {
            // View translation → source translation (`interiorDragGesture`, `:253-270`).
            Grab::Interior => crop::snapped_translated_rect(drag.start, (dx / fit.scale, dy / fit.scale), fit.source_w, fit.source_h, input.alignment),
            // The corner's start point plus the translation, mapped to source (`handleDragGesture`, `:278-304`).
            Grab::Corner(c) => {
                let (x, y) = fit.view_rect(drag.start).corner(c);
                let p = fit.source_point((x + dx, y + dy));
                crop::snapped_resized_rect(drag.start, c, p, fit.source_w, fit.source_h, input.alignment)
            }
        };
        (next != source_rect).then_some(next)
    }
}

/// 55 % black over the fitted picture with the crop punched out (`dimMask`, even-odd fill, `:191-198`).
fn dim_mask(p: &Painter, fitted: egui::Rect, crop: egui::Rect) {
    let c = crop.intersect(fitted);
    let fill = Color32::from_black_alpha(140);
    if !c.is_positive() {
        p.rect_filled(fitted, 0.0, fill);
        return;
    }
    let parts = [
        egui::Rect::from_min_max(fitted.min, pos2(fitted.max.x, c.min.y)),
        egui::Rect::from_min_max(pos2(fitted.min.x, c.max.y), fitted.max),
        egui::Rect::from_min_max(pos2(fitted.min.x, c.min.y), pos2(c.min.x, c.max.y)),
        egui::Rect::from_min_max(pos2(c.max.x, c.min.y), pos2(fitted.max.x, c.max.y)),
    ];
    for r in parts.into_iter().filter(|r| r.is_positive()) {
        p.rect_filled(r, 0.0, fill);
    }
}
