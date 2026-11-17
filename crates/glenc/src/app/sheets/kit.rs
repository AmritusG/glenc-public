//! What the Preferences window and the sheets share: SwiftUI's text styles and stock macOS controls in egui, the
//! middle truncation (`.truncationMode(.middle)`), and the SF Symbols the sheets show, drawn as vector shapes
//! (SF Symbols are Apple's and drawable only through AppKit / SwiftUI).

use crate::app::look;
use egui::{Color32, CornerRadius, FontFamily, FontId, Painter, Pos2, Rect, Response, RichText, Shape, Stroke, Ui, pos2, vec2};

/// `.font(.headline)`: 13 pt semibold.
pub fn headline() -> FontId {
    FontId::new(look::size::HEADLINE, FontFamily::Name(glance_ui::fonts::SEMIBOLD.into()))
}

/// `.font(.system(size:))`.
pub fn system(size: f32) -> FontId {
    FontId::proportional(size)
}

/// `.font(.system(size:, design: .monospaced))`.
pub fn mono(size: f32) -> FontId {
    FontId::monospace(size)
}

/// `.font(.caption)`.
pub fn caption() -> FontId {
    FontId::proportional(look::size::CAPTION)
}

/// The spacing of AppKit's regular-size controls (glance-ui's look zeroes the button padding for its transport bar).
pub fn mac_spacing(ui: &mut Ui) {
    let s = ui.spacing_mut();
    s.item_spacing = vec2(8.0, 8.0);
    s.button_padding = vec2(10.0, 2.0);
    s.interact_size.y = 22.0;
    s.icon_width = 14.0;
    s.icon_width_inner = 8.0;
    s.icon_spacing = 6.0;
}

/// A wrapping text (`Text(…)` in a `VStack`).
pub fn text(ui: &mut Ui, s: impl Into<String>, font: FontId, color: Color32) -> Response {
    ui.add(egui::Label::new(RichText::new(s).font(font).color(color)).wrap())
}

/// A one-line text cut in the middle with "…" to fit `max_width` (`.lineLimit(1).truncationMode(.middle)`).
pub fn elide_middle(ctx: &egui::Context, s: &str, font: &FontId, max_width: f32) -> String {
    let width = |t: &str| ctx.fonts_mut(|f| f.layout_no_wrap(t.to_owned(), font.clone(), Color32::WHITE).size().x);
    if width(s) <= max_width {
        return s.to_owned();
    }
    let chars: Vec<char> = s.chars().collect();
    let cut = |keep: usize| -> String {
        let head = keep.div_ceil(2);
        let tail = keep / 2;
        let mut o: String = chars[..head].iter().collect();
        o.push('…');
        o.extend(&chars[chars.len() - tail..]);
        o
    };
    // The most characters that still fit (binary search over the kept count).
    let (mut lo, mut hi) = (0usize, chars.len());
    while lo < hi {
        let mid = (lo + hi).div_ceil(2);
        if width(&cut(mid)) <= max_width { lo = mid } else { hi = mid - 1 }
    }
    cut(lo)
}

/// A one-line, middle-truncated text filling the width left in `ui`.
pub fn elided(ui: &mut Ui, s: &str, font: FontId, color: Color32, max_width: f32) -> Response {
    let shown = elide_middle(ui.ctx(), s, &font, max_width);
    let r = ui.add(egui::Label::new(RichText::new(shown.clone()).font(font).color(color)).extend());
    if shown != s { r.on_hover_text(s) } else { r }
}

/// A push button.
pub fn button(ui: &mut Ui, label: &str, enabled: bool) -> Response {
    ui.add_enabled(enabled, egui::Button::new(RichText::new(label).font(system(look::size::BODY))).min_size(vec2(64.0, 0.0)))
}

/// The window's default button (`.keyboardShortcut(.defaultAction)`): accent-filled, ↩.
pub fn default_button(ui: &mut Ui, label: &str, enabled: bool) -> Response {
    let text = RichText::new(label).font(system(look::size::BODY)).color(Color32::WHITE);
    let b = egui::Button::new(text).min_size(vec2(64.0, 0.0));
    let b = if enabled { b.fill(look::ACCENT) } else { b };
    ui.add_enabled(enabled, b)
}

/// A sheet's face: the window background, the sheet's corner and border, `.padding(20)`.
pub fn sheet_frame() -> egui::Frame {
    egui::Frame::new()
        .fill(Color32::from_rgb(40, 40, 40))
        .corner_radius(CornerRadius::same(10))
        .stroke(Stroke::new(1.0, look::SEPARATOR))
        .inner_margin(20)
        .shadow(egui::epaint::Shadow { offset: [0, 8], blur: 24, spread: 0, color: Color32::from_black_alpha(120) })
}

/// Esc / ↩ for a sheet, taken before its fields see them (AppKit sends key equivalents to the buttons first).
pub fn sheet_keys(ctx: &egui::Context, default_enabled: bool) -> (bool, bool) {
    ctx.input_mut(|i| {
        let esc = i.consume_key(egui::Modifiers::NONE, egui::Key::Escape);
        let ret = default_enabled && i.consume_key(egui::Modifiers::NONE, egui::Key::Enter);
        (esc, ret)
    })
}

// MARK: - SF Symbols as shapes

/// Reserve a `w`-wide column, `h` tall, for a symbol; returns its square.
pub fn symbol_slot(ui: &mut Ui, w: f32, size: f32) -> Rect {
    let (rect, _) = ui.allocate_exact_size(vec2(w, size), egui::Sense::hover());
    Rect::from_center_size(rect.center(), vec2(size, size))
}

/// `exclamationmark.triangle.fill`.
pub fn warning_triangle(p: &Painter, r: Rect, color: Color32, knockout: Color32) {
    let s = r.width();
    let top = pos2(r.center().x, r.top() + s * 0.08);
    let left = pos2(r.left() + s * 0.02, r.bottom() - s * 0.1);
    let right = pos2(r.right() - s * 0.02, r.bottom() - s * 0.1);
    p.add(Shape::convex_polygon(vec![top, right, left], color, Stroke::new(s * 0.06, color)));
    let x = r.center().x;
    let bar = Rect::from_min_max(pos2(x - s * 0.045, r.top() + s * 0.36), pos2(x + s * 0.045, r.top() + s * 0.66));
    p.rect_filled(bar, CornerRadius::same((s * 0.04) as u8), knockout);
    p.circle_filled(pos2(x, r.top() + s * 0.76), s * 0.055, knockout);
}

fn arrow_head(p: &Painter, tip: Pos2, dir: f32, half: f32, stroke: Stroke) {
    p.line_segment([tip, pos2(tip.x - half, tip.y - dir * half)], stroke);
    p.line_segment([tip, pos2(tip.x + half, tip.y - dir * half)], stroke);
}

/// `rectangle.expand.vertical`: a box with a vertical double arrow.
pub fn expand_vertical(p: &Painter, r: Rect, color: Color32) {
    let s = r.width();
    let stroke = Stroke::new(s * 0.06, color);
    let body = Rect::from_center_size(r.center(), vec2(s * 0.86, s * 0.62));
    p.rect_stroke(body, CornerRadius::same((s * 0.1) as u8), stroke, egui::StrokeKind::Middle);
    let x = r.center().x;
    let (t, b) = (r.top() + s * 0.04, r.bottom() - s * 0.04);
    p.line_segment([pos2(x, t), pos2(x, b)], stroke);
    arrow_head(p, pos2(x, t), -1.0, s * 0.13, stroke);
    arrow_head(p, pos2(x, b), 1.0, s * 0.13, stroke);
}

/// `rectangle.stack`: a box with two narrower ones stacked behind it.
pub fn rectangle_stack(p: &Painter, r: Rect, color: Color32) {
    let s = r.width();
    let stroke = Stroke::new(s * 0.06, color);
    let front = Rect::from_min_max(pos2(r.left() + s * 0.06, r.top() + s * 0.36), pos2(r.right() - s * 0.06, r.bottom() - s * 0.1));
    p.rect_stroke(front, CornerRadius::same((s * 0.08) as u8), stroke, egui::StrokeKind::Middle);
    for (inset, y) in [(0.16, 0.25), (0.26, 0.14)] {
        p.line_segment([pos2(r.left() + s * inset, r.top() + s * y), pos2(r.right() - s * inset, r.top() + s * y)], stroke);
    }
}

/// `trash`.
pub fn trash(p: &Painter, r: Rect, color: Color32) {
    let s = r.width();
    let stroke = Stroke::new(s * 0.09, color);
    let lid_y = r.top() + s * 0.22;
    p.line_segment([pos2(r.left() + s * 0.1, lid_y), pos2(r.right() - s * 0.1, lid_y)], stroke);
    p.line_segment([pos2(r.center().x - s * 0.14, r.top() + s * 0.08), pos2(r.center().x + s * 0.14, r.top() + s * 0.08)], stroke);
    let body = [
        pos2(r.left() + s * 0.2, lid_y),
        pos2(r.left() + s * 0.26, r.bottom() - s * 0.06),
        pos2(r.right() - s * 0.26, r.bottom() - s * 0.06),
        pos2(r.right() - s * 0.2, lid_y),
    ];
    p.add(Shape::line(body.to_vec(), stroke));
}
