//! The controls the rows and the settings bar share, drawn as SwiftUI's stock macOS dark-mode controls: the
//! borderless menus with the `chevron.up.chevron.down` glyph before the label (`JobCardView.rowChevronStyle`,
//! `SettingsBarView.barMenu`), small push buttons (`.controlSize(.small)`), pop-up pickers, the segmented
//! picker, the small linear progress bar, number fields (`TextField(value:format: .number)`), the HAP Chunks
//! tap-stepper (`HapChunksStepper`), the H.264 / HEVC Advanced controls (`VideoAdvancedControls`), the menus'
//! items (`SettingsMenuItems.swift`, `OutputSizeMenuItems`) and the SF Symbols the rows use, drawn as vectors.
//!
//! Every settings edit is returned as an [`Edit`] for the caller to route (one row, the selection, the defaults),
//! as Swift's `apply` closures do.

use super::rows_logic as logic;
use crate::app::look;
use crate::job::{Family, JobSettings};
use crate::json::NamedSize;
use crate::settings::AlphaMode;
use egui::{Align2, Button, Color32, FontFamily, FontId, Id, Painter, Pos2, Rect, Response, RichText, Sense, Shape, Stroke, Ui, Vec2, pos2, vec2};
use glance_encode::audio::AudioRate;
use glance_encode::codec::{OutputCodec, OutputContainer, ProResVariant, RateControl};
use glance_encode::size::{AspectMode, OutputSize, ResizeQuality, StandardResolution};
use glance_encode::source::AlphaType;

/// A settings edit (Swift's `EncodeQueue.SettingsEdit`): the settings and the row's source alpha.
pub type Edit = Box<dyn Fn(&mut JobSettings, Option<bool>)>;

pub fn edit(f: impl Fn(&mut JobSettings, Option<bool>) + 'static) -> Edit {
    Box::new(f)
}

// MARK: - Look

/// Disabled text (`disabledControlTextColor`, dark: white 25 %).
pub const DISABLED: Color32 = Color32::from_rgb(88, 88, 88);
/// The fill behind the drop zone (`Color.gray.opacity(0.06)` over the window).
pub const DROP_FILL: Color32 = Color32::from_rgb(37, 37, 37);
/// `Color.accentColor.opacity(0.15)` over the window.
pub const DROP_FILL_TARGETED: Color32 = Color32::from_rgb(27, 45, 69);
/// `Color.secondary.opacity(0.5)` over the window.
pub const DROP_STROKE: Color32 = Color32::from_rgb(91, 91, 91);
/// A text field's face (dark `textBackgroundColor` inside a rounded border).
pub const FIELD: Color32 = Color32::from_rgb(40, 40, 40);
pub const FIELD_BORDER: Color32 = Color32::from_rgb(72, 72, 72);
/// The progress bar's empty track.
pub const TRACK: Color32 = Color32::from_rgb(58, 58, 58);
/// A segmented picker's selected segment.
pub const SEGMENT_ON: Color32 = Color32::from_rgb(99, 99, 99);
/// The popover / menu face.
pub const POPOVER: Color32 = Color32::from_rgb(44, 44, 44);
/// The height of a borderless menu row (13 pt text).
pub const MENU_HEIGHT: f32 = 16.0;

pub fn font(size: f32) -> FontId {
    FontId::proportional(size)
}

pub fn medium(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name(glance_ui::fonts::MEDIUM.into()))
}

pub fn semibold(size: f32) -> FontId {
    FontId::new(size, FontFamily::Name(glance_ui::fonts::SEMIBOLD.into()))
}

pub fn mono(size: f32) -> FontId {
    FontId::monospace(size)
}

/// A one-line label that never wraps.
pub fn text(ui: &mut Ui, s: impl Into<String>, font: FontId, color: Color32) -> Response {
    ui.add(egui::Label::new(RichText::new(s.into()).font(font).color(color)).wrap_mode(egui::TextWrapMode::Extend).selectable(false))
}

/// `.help(…)`: the tooltip, shown on a disabled control too (AppKit tooltips are).
pub fn help(resp: Response, s: &str) -> Response {
    if s.is_empty() {
        return resp;
    }
    resp.on_hover_text(s).on_disabled_hover_text(s)
}

/// The width of `s` in `font`.
pub fn width_of(ui: &Ui, s: &str, font: &FontId) -> f32 {
    ui.painter().layout_no_wrap(s.to_owned(), font.clone(), Color32::WHITE).size().x
}

// MARK: - Glyphs (SF Symbols as vectors)

/// `chevron.up.chevron.down` at `size` points.
pub fn chevrons(p: &Painter, c: Pos2, size: f32, color: Color32) {
    let w = size * 0.32;
    let h = size * 0.22;
    let gap = size * 0.1;
    let stroke = Stroke::new((size * 0.13).max(1.0), color);
    p.add(Shape::line(vec![pos2(c.x - w, c.y - gap), pos2(c.x, c.y - gap - h), pos2(c.x + w, c.y - gap)], stroke));
    p.add(Shape::line(vec![pos2(c.x - w, c.y + gap), pos2(c.x, c.y + gap + h), pos2(c.x + w, c.y + gap)], stroke));
}

/// `xmark` at `size` points.
pub fn xmark(p: &Painter, c: Pos2, size: f32, color: Color32) {
    let r = size * 0.36;
    let stroke = Stroke::new(size * 0.15, color);
    p.line_segment([pos2(c.x - r, c.y - r), pos2(c.x + r, c.y + r)], stroke);
    p.line_segment([pos2(c.x - r, c.y + r), pos2(c.x + r, c.y - r)], stroke);
}

/// `exclamationmark.triangle.fill` at `size` points.
pub fn warning_triangle(p: &Painter, c: Pos2, size: f32, color: Color32) {
    let h = size * 0.86;
    let w = size * 0.98;
    let top = pos2(c.x, c.y - h * 0.55);
    p.add(Shape::convex_polygon(vec![top, pos2(c.x + w / 2.0, c.y + h * 0.45), pos2(c.x - w / 2.0, c.y + h * 0.45)], color, Stroke::new(size * 0.06, color)));
    let mark = Stroke::new(size * 0.11, look::WINDOW);
    p.line_segment([pos2(c.x, c.y - h * 0.18), pos2(c.x, c.y + h * 0.13)], mark);
    p.circle_filled(pos2(c.x, c.y + h * 0.29), size * 0.065, look::WINDOW);
}

fn arc(c: Pos2, r: f32, a0: f32, a1: f32) -> Vec<Pos2> {
    let n = 24;
    (0..=n).map(|i| a0 + (a1 - a0) * i as f32 / n as f32).map(|a| pos2(c.x + r * a.cos(), c.y + r * a.sin())).collect()
}

/// `arrow.counterclockwise.circle` at `size` points.
pub fn reset_circle(p: &Painter, c: Pos2, size: f32, color: Color32) {
    let stroke = Stroke::new(size * 0.08, color);
    p.circle_stroke(c, size * 0.45, stroke);
    let r = size * 0.22;
    let pts = arc(c, r, -1.25, 3.9);
    p.add(Shape::line(pts.clone(), stroke));
    if let Some(&start) = pts.first() {
        let s = size * 0.13;
        p.add(Shape::convex_polygon(
            vec![pos2(start.x - s * 1.3, start.y), pos2(start.x + s * 0.4, start.y - s), pos2(start.x + s * 0.4, start.y + s)],
            color,
            Stroke::NONE,
        ));
    }
}

/// `speaker.slash` at `size` points.
pub fn speaker_slash(p: &Painter, c: Pos2, size: f32, color: Color32) {
    let s = size / 10.0;
    let stroke = Stroke::new(0.9 * s, color);
    let body = vec![
        pos2(c.x - 4.0 * s, c.y - 1.6 * s),
        pos2(c.x - 2.2 * s, c.y - 1.6 * s),
        pos2(c.x + 1.2 * s, c.y - 4.2 * s),
        pos2(c.x + 1.2 * s, c.y + 4.2 * s),
        pos2(c.x - 2.2 * s, c.y + 1.6 * s),
        pos2(c.x - 4.0 * s, c.y + 1.6 * s),
    ];
    p.add(Shape::closed_line(body, stroke));
    p.line_segment([pos2(c.x - 4.5 * s, c.y - 4.5 * s), pos2(c.x + 4.5 * s, c.y + 4.5 * s)], stroke);
}

/// `square.and.arrow.down` at `size` points.
pub fn tray_arrow_down(p: &Painter, c: Pos2, size: f32, color: Color32) {
    let s = size / 28.0;
    let stroke = Stroke::new(2.0 * s, color);
    let (l, r, t, b) = (c.x - 10.0 * s, c.x + 10.0 * s, c.y - 4.0 * s, c.y + 13.0 * s);
    p.add(Shape::line(vec![pos2(c.x - 4.0 * s, t), pos2(l, t), pos2(l, b), pos2(r, b), pos2(r, t), pos2(c.x + 4.0 * s, t)], stroke));
    p.line_segment([pos2(c.x, c.y - 14.0 * s), pos2(c.x, c.y + 6.0 * s)], stroke);
    p.add(Shape::line(vec![pos2(c.x - 5.0 * s, c.y + 1.0 * s), pos2(c.x, c.y + 6.0 * s), pos2(c.x + 5.0 * s, c.y + 1.0 * s)], stroke));
}

/// `square.stack.3d.up` at `size` points.
pub fn stack_3d(p: &Painter, c: Pos2, size: f32, color: Color32) {
    let s = size / 10.0;
    let stroke = Stroke::new(0.9 * s, color);
    let diamond = |cy: f32| vec![pos2(c.x, cy - 2.2 * s), pos2(c.x + 4.4 * s, cy), pos2(c.x, cy + 2.2 * s), pos2(c.x - 4.4 * s, cy)];
    p.add(Shape::closed_line(diamond(c.y - 2.4 * s), stroke));
    p.add(Shape::line(vec![pos2(c.x - 4.4 * s, c.y + 0.2 * s), pos2(c.x, c.y + 2.4 * s), pos2(c.x + 4.4 * s, c.y + 0.2 * s)], stroke));
    p.add(Shape::line(vec![pos2(c.x - 4.4 * s, c.y + 2.6 * s), pos2(c.x, c.y + 4.8 * s), pos2(c.x + 4.4 * s, c.y + 2.6 * s)], stroke));
}

/// An icon followed by text, in one row ("⚠ Done · no audio"), at `font`'s size; returns the response.
pub fn icon_text(ui: &mut Ui, icon: fn(&Painter, Pos2, f32, Color32), icon_size: f32, spacing: f32, s: &str, font: FontId, color: Color32) -> Response {
    let galley = ui.painter().layout_no_wrap(s.to_owned(), font, color);
    let h = galley.size().y.max(icon_size);
    let size = vec2(icon_size + spacing + galley.size().x, h);
    let (rect, resp) = ui.allocate_exact_size(size, Sense::hover());
    icon(ui.painter(), pos2(rect.left() + icon_size / 2.0, rect.center().y), icon_size, color);
    ui.painter().galley(pos2(rect.left() + icon_size + spacing, rect.center().y - galley.size().y / 2.0), galley, color);
    resp
}

// MARK: - Borderless menus

/// The label of a borderless menu: the chevron glyph (9 pt, secondary), 4 pt, the text (13 pt).
pub fn menu_label(ui: &mut Ui, label: &str, enabled: bool) -> Response {
    let color = if enabled { look::TEXT } else { DISABLED };
    let galley = ui.painter().layout_no_wrap(label.to_owned(), font(look::size::BODY), color);
    let chev = 6.0;
    let size = vec2(chev + 4.0 + galley.size().x, MENU_HEIGHT.max(galley.size().y));
    let (rect, resp) = ui.allocate_exact_size(size, if enabled { Sense::click() } else { Sense::hover() });
    let glyph = if enabled { look::SECONDARY } else { DISABLED };
    chevrons(ui.painter(), pos2(rect.left() + chev / 2.0, rect.center().y), 9.0, glyph);
    ui.painter().galley(pos2(rect.left() + chev + 4.0, rect.center().y - galley.size().y / 2.0), galley, color);
    resp
}

/// A borderless menu: its label; a click opens `content` below it. Returns the label's response (for `help`).
pub fn menu(ui: &mut Ui, label: &str, enabled: bool, content: impl FnOnce(&mut Ui)) -> Response {
    let resp = menu_label(ui, label, enabled);
    egui::Popup::menu(&resp).frame(menu_frame(ui)).show(|ui| {
        menu_look(ui);
        content(ui);
    });
    resp
}

pub fn menu_frame(ui: &Ui) -> egui::Frame {
    egui::Frame::popup(ui.style()).fill(POPOVER).inner_margin(egui::Margin::symmetric(5, 5)).corner_radius(6)
}

/// A macOS menu's look: 13 pt items, the accent highlight under the pointer.
pub fn menu_look(ui: &mut Ui) {
    let v = ui.visuals_mut();
    v.override_text_color = None;
    v.widgets.inactive.fg_stroke.color = look::TEXT;
    v.widgets.hovered.fg_stroke.color = Color32::WHITE;
    v.widgets.active.fg_stroke.color = Color32::WHITE;
    v.widgets.hovered.weak_bg_fill = look::SELECTED_ROW;
    v.widgets.hovered.bg_fill = look::SELECTED_ROW;
    v.widgets.active.weak_bg_fill = look::SELECTED_ROW;
    v.widgets.active.bg_fill = look::SELECTED_ROW;
    v.widgets.hovered.corner_radius = egui::CornerRadius::same(4);
    v.widgets.active.corner_radius = egui::CornerRadius::same(4);
    v.widgets.noninteractive.bg_stroke = Stroke::new(1.0, look::SEPARATOR);
    ui.spacing_mut().button_padding = vec2(10.0, 2.0);
    ui.spacing_mut().item_spacing = vec2(0.0, 0.0);
    ui.spacing_mut().interact_size.y = 20.0;
    ui.set_min_width(150.0);
}

/// A menu item; true when chosen.
pub fn item(ui: &mut Ui, label: &str, enabled: bool) -> bool {
    ui.add_enabled(enabled, Button::new(RichText::new(label).font(font(look::size::BODY))).wrap_mode(egui::TextWrapMode::Extend)).clicked()
}

/// A menu's `Section` header.
pub fn section(ui: &mut Ui, title: &str) {
    ui.add_space(3.0);
    ui.horizontal(|ui| {
        ui.add_space(10.0);
        text(ui, title, font(11.0), look::SECONDARY);
    });
    ui.add_space(1.0);
}

/// A menu's `Divider`.
pub fn divider(ui: &mut Ui) {
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 9.0), Sense::hover());
    ui.painter().hline(rect.x_range().shrink(10.0), rect.center().y, Stroke::new(1.0, look::SEPARATOR));
}

// MARK: - Buttons

/// A push button at `.controlSize(.small)` (11 pt, 16 pt tall, as measured beside Swift); `default` draws it in the accent colour
/// (`.keyboardShortcut(.defaultAction)`).
pub fn small_button(ui: &mut Ui, label: &str, enabled: bool, default: bool) -> Response {
    ui.scope(|ui| {
        ui.spacing_mut().button_padding = vec2(8.0, 1.0);
        let color = if !enabled {
            DISABLED
        } else if default {
            Color32::WHITE
        } else {
            look::TEXT
        };
        let fill = if default && enabled { look::ACCENT } else { look::BUTTON };
        let b = Button::new(RichText::new(label).font(font(look::size::SMALL_CONTROL)).color(color))
            .fill(fill)
            .stroke(Stroke::NONE)
            .corner_radius(4)
            .min_size(vec2(0.0, 16.0));
        ui.add_enabled(enabled, b)
    })
    .inner
}

/// A borderless icon button of `size` points.
pub fn icon_button(ui: &mut Ui, size: Vec2, enabled: bool, paint: impl FnOnce(&Painter, Pos2, Color32)) -> Response {
    let (rect, resp) = ui.allocate_exact_size(size, if enabled { Sense::click() } else { Sense::hover() });
    let color = if !enabled {
        DISABLED
    } else if resp.is_pointer_button_down_on() {
        Color32::WHITE
    } else {
        look::TEXT
    };
    paint(ui.painter(), rect.center(), color);
    resp
}

/// A pop-up button (`Picker` in `.menu` style): face, text, the chevrons in an accent box on the right.
pub fn popup_button(ui: &mut Ui, label: &str, enabled: bool, content: impl FnOnce(&mut Ui)) -> Response {
    let f = font(look::size::BODY);
    let galley = ui.painter().layout_no_wrap(label.to_owned(), f, if enabled { look::TEXT } else { DISABLED });
    let size = vec2(galley.size().x + 8.0 + 6.0 + 16.0 + 2.0, 17.0);
    let (rect, resp) = ui.allocate_exact_size(size, if enabled { Sense::click() } else { Sense::hover() });
    let p = ui.painter();
    p.rect_filled(rect, 5.0, look::BUTTON);
    p.galley(pos2(rect.left() + 8.0, rect.center().y - galley.size().y / 2.0), galley, look::TEXT);
    let boxr = Rect::from_center_size(pos2(rect.right() - 10.0, rect.center().y), vec2(16.0, 16.0));
    p.rect_filled(boxr, 4.0, if enabled { look::ACCENT } else { DISABLED });
    chevrons(p, boxr.center(), 10.0, Color32::WHITE);
    egui::Popup::menu(&resp).frame(menu_frame(ui)).show(|ui| {
        menu_look(ui);
        content(ui);
    });
    resp
}

/// A segmented picker (`.pickerStyle(.segmented)`); returns the chosen index when it changed.
pub fn segmented(ui: &mut Ui, labels: &[&str], selected: usize) -> Option<usize> {
    let f = font(look::size::BODY);
    let widths: Vec<f32> = labels.iter().map(|l| width_of(ui, l, &f) + 20.0).collect();
    let seg = widths.iter().copied().fold(0.0, f32::max);
    let total = vec2(seg * labels.len() as f32 + 2.0, 17.0);
    let (rect, _) = ui.allocate_exact_size(total, Sense::hover());
    ui.painter().rect_filled(rect, 5.0, look::BUTTON.linear_multiply(0.7));
    let mut out = None;
    for (i, l) in labels.iter().enumerate() {
        let r = Rect::from_min_size(pos2(rect.left() + 1.0 + seg * i as f32, rect.top() + 1.0), vec2(seg, rect.height() - 2.0));
        let resp = ui.interact(r, ui.id().with(("segment", i)), Sense::click());
        if i == selected {
            ui.painter().rect_filled(r, 4.0, SEGMENT_ON);
        } else if i > 0 && i != selected + 1 {
            ui.painter().vline(r.left(), r.y_range().shrink(4.0), Stroke::new(1.0, look::SEPARATOR));
        }
        ui.painter().text(r.center(), Align2::CENTER_CENTER, *l, f.clone(), look::TEXT);
        if resp.clicked() && i != selected {
            out = Some(i);
        }
    }
    out
}

/// The small linear progress bar (`ProgressView(value:).controlSize(.small)`).
pub fn progress_bar(ui: &mut Ui, width: f32, value: f64) -> Response {
    let (rect, resp) = ui.allocate_exact_size(vec2(width, 12.0), Sense::hover());
    let track = Rect::from_center_size(rect.center(), vec2(rect.width(), 4.0));
    ui.painter().rect_filled(track, 2.0, TRACK);
    let fill = (value.clamp(0.0, 1.0) as f32) * track.width();
    if fill > 0.0 {
        ui.painter().rect_filled(Rect::from_min_size(track.min, vec2(fill, track.height())), 2.0, look::ACCENT);
    }
    resp
}

// MARK: - Fields

/// A number field (`TextField(value:, format: .number)`): shows the value; while focused keeps what is typed;
/// Return or leaving the field commits a number (else the value comes back).
pub fn number_field(ui: &mut Ui, id: Id, value: f64, width: f32) -> Option<f64> {
    let focused = ui.memory(|m| m.has_focus(id));
    let mut s = if focused { ui.data(|d| d.get_temp::<String>(id)).unwrap_or_else(|| logic::format_number(value)) } else { logic::format_number(value) };
    let resp = ui.add(
        egui::TextEdit::singleline(&mut s)
            .id(id)
            .font(font(look::size::BODY))
            .text_color(look::TEXT)
            .desired_width(width)
            .margin(egui::Margin::symmetric(4, 2))
            .background_color(FIELD),
    );
    if resp.has_focus() {
        ui.data_mut(|d| d.insert_temp(id, s.clone()));
    }
    if resp.lost_focus() {
        ui.data_mut(|d| d.remove::<String>(id));
        return logic::parse_number(&s).filter(|v| *v != value);
    }
    None
}

// MARK: - HAP Chunks stepper

/// "Chunks: 4 ⇕": a tap on the upper half adds one, on the lower half takes one (`HapChunksStepper`).
pub fn chunks_stepper(ui: &mut Ui, value: &str, enabled: bool) -> (Response, i64) {
    let mut delta = 0;
    let color = if enabled { look::TEXT } else { DISABLED };
    let resp = ui
        .horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 4.0;
            text(ui, "Chunks:", font(look::size::BODY), color);
            let (r, _) = ui.allocate_exact_size(vec2(18.0, MENU_HEIGHT), Sense::hover());
            ui.painter().text(pos2(r.right(), r.center().y), Align2::RIGHT_CENTER, value, mono(12.0), color);
            let (r, _) = ui.allocate_exact_size(vec2(12.0, MENU_HEIGHT), Sense::hover());
            chevrons(ui.painter(), r.center(), 12.0, if enabled { Color32::WHITE } else { DISABLED });
            let sense = if enabled { Sense::click() } else { Sense::hover() };
            let up = ui.interact(Rect::from_min_max(r.min, pos2(r.max.x, r.center().y)), ui.id().with("chunks+"), sense);
            let down = ui.interact(Rect::from_min_max(pos2(r.min.x, r.center().y), r.max), ui.id().with("chunks-"), sense);
            if up.clicked() {
                delta = 1;
            }
            if down.clicked() {
                delta = -1;
            }
        })
        .response;
    let resp = help(
        resp,
        "HAP chunked-section count (1–64). 1 = single section. Higher splits each frame into more independently-decodable chunks for parallel GPU upload.",
    );
    (resp, delta)
}

// MARK: - Menu items (`SettingsMenuItems.swift`)

/// `CodecFamilyMenuItems`.
pub fn codec_family_items(ui: &mut Ui) -> Option<Edit> {
    let mut out = None;
    for (i, f) in Family::ALL.into_iter().enumerate() {
        if i == 4 {
            divider(ui);
        }
        if item(ui, f.label(), true) {
            out = Some(edit(move |s, a| s.select_family(f, a)));
        }
    }
    out
}

/// `AlphaMenuItems`.
pub fn alpha_items(ui: &mut Ui) -> Option<Edit> {
    let mut out = None;
    for m in AlphaMode::ALL.iter().copied() {
        if item(ui, m.label(), true) {
            out = Some(edit(move |s, _| s.set_alpha(m)));
        }
    }
    out
}

/// `SourceAlphaTypeMenuItems`.
pub fn alpha_type_items(ui: &mut Ui) -> Option<Edit> {
    let mut out = None;
    for t in [AlphaType::Premultiplied, AlphaType::Straight] {
        if item(ui, logic::alpha_type_label(t), true) {
            out = Some(edit(move |s, _| s.alpha_type = t));
        }
    }
    out
}

/// `ProResVariantMenuItems`.
pub fn prores_items(ui: &mut Ui) -> Option<Edit> {
    let mut out = None;
    for v in ProResVariant::ALL {
        if item(ui, v.label(), true) {
            out = Some(edit(move |s, _| s.set_prores_variant(v)));
        }
    }
    out
}

/// `ContainerMenuItems` (the bar: both containers) or the row's (the codec's allowed containers).
pub fn container_items(ui: &mut Ui, containers: &[OutputContainer]) -> Option<Edit> {
    let mut out = None;
    for c in containers.iter().copied() {
        if item(ui, c.label(), true) {
            out = Some(edit(move |s, _| s.set_container(c)));
        }
    }
    out
}

/// `AudioEnabledMenuItems`.
pub fn audio_enabled_items(ui: &mut Ui) -> Option<Edit> {
    let mut out = None;
    if item(ui, "Audio: On", true) {
        out = Some(edit(|s, _| s.audio_enabled = true));
    }
    if item(ui, "Audio: Off (strip)", true) {
        out = Some(edit(|s, _| s.audio_enabled = false));
    }
    out
}

/// `AudioRateMenuItems`: a rate no target's container can carry is disabled; the AAC note when a target is `.mp4`.
pub fn audio_rate_items(ui: &mut Ui, targets: &[JobSettings]) -> Option<Edit> {
    let mut out = None;
    for r in AudioRate::ALL {
        let unavailable = !targets.is_empty() && targets.iter().all(|t| t.audio_rate_unavailable(r));
        if item(ui, r.label(), !unavailable) {
            out = Some(edit(move |s, _| s.set_audio_rate(r)));
        }
    }
    if targets.iter().any(|t| t.container.uses_aac()) {
        divider(ui);
        item(ui, "MPEG-4 (AAC) caps at 48 kHz", false);
    }
    out
}

/// `ResizeQualityMenuItems`.
pub fn resize_quality_items(ui: &mut Ui) -> Option<Edit> {
    let mut out = None;
    for q in ResizeQuality::ALL {
        if item(ui, q.label(), true) {
            out = Some(edit(move |s, _| s.resize_quality = q));
        }
    }
    out
}

/// `AspectMenuItems`.
pub fn aspect_items(ui: &mut Ui) -> Option<Edit> {
    let mut out = None;
    for m in [AspectMode::Letterbox, AspectMode::DistortToFill] {
        if item(ui, m.label(), true) {
            out = Some(edit(move |s, _| s.aspect = m));
        }
    }
    out
}

/// What the Size menu chose.
pub enum SizeChoice {
    Size(OutputSize),
    Custom,
    Manage,
}

/// `OutputSizeMenuItems`: Original, My Sizes, the sections, Custom…, Manage Sizes… (only with saved sizes).
pub fn output_size_items(ui: &mut Ui, original: &str, presets: &[NamedSize]) -> Option<SizeChoice> {
    let mut out = None;
    if item(ui, original, true) {
        out = Some(SizeChoice::Size(OutputSize::Original));
    }
    if !presets.is_empty() {
        section(ui, "My Sizes");
        for p in presets {
            if item(ui, &format!("{} — {}×{}", p.name, p.width, p.height), true) {
                out = Some(SizeChoice::Size(OutputSize::Custom { width: p.width, height: p.height }));
            }
        }
    }
    use StandardResolution as R;
    let sections: [(&str, &[R]); 4] = [
        ("HD / UHD", &[R::Hd1280x720, R::Fhd1920x1080, R::Qhd2560x1440, R::Uhd3840x2160]),
        ("DCI Cinema", &[R::Dci2048x1080, R::Dci4096x2160]),
        ("Square", &[R::Sq1024, R::Sq1080, R::Sq2048]),
        ("Vertical", &[R::V720x1280, R::V1080x1920, R::V1440x2560]),
    ];
    for (title, list) in sections {
        section(ui, title);
        for r in list {
            if item(ui, r.label(), true) {
                out = Some(SizeChoice::Size(OutputSize::Preset(*r)));
            }
        }
    }
    divider(ui);
    if item(ui, "Custom…", true) {
        out = Some(SizeChoice::Custom);
    }
    if !presets.is_empty() && item(ui, "Manage Sizes…", true) {
        out = Some(SizeChoice::Manage);
    }
    out
}

/// The tier label of the first menu (`JobSettings.codecFamilyLabel`).
pub fn family_label(s: &JobSettings) -> &'static str {
    s.family().label()
}

/// The DXV / HAP alpha menu's label (`format.alphaMode.label`).
pub fn alpha_label(s: &JobSettings) -> &'static str {
    crate::settings::alpha_of(s.format).label()
}

// MARK: - Advanced (`VideoAdvancedControls`)

/// The H.264 / HEVC rate-control knobs for `s` (shown values), as sibling rows; returns the edit made.
pub fn video_advanced(ui: &mut Ui, id: Id, s: &JobSettings) -> Option<Edit> {
    let mut out: Option<Edit> = None;
    let quality = match s.video.rate_control {
        RateControl::Quality(q) => Some(q),
        RateControl::Bitrate(_) => None,
    };
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 8.0;
        text(ui, "Rate control:", font(look::size::BODY), look::TEXT);
        if let Some(i) = segmented(ui, &["Quality", "Bitrate"], if quality.is_some() { 0 } else { 1 }) {
            out = Some(edit(move |s, _| s.set_rate_control_mode(i == 0)));
        }
    });
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 8.0;
        match s.video.rate_control {
            RateControl::Quality(q) => {
                text(ui, "Quality:", font(look::size::BODY), look::TEXT);
                let mut v = q;
                ui.spacing_mut().slider_width = (ui.available_width() - 42.0).max(60.0);
                if ui.add(egui::Slider::new(&mut v, 0.1..=1.0).show_value(false)).changed() {
                    out = Some(edit(move |s, _| s.set_quality(v)));
                }
                let (r, _) = ui.allocate_exact_size(vec2(34.0, MENU_HEIGHT), Sense::hover());
                ui.painter().text(pos2(r.right(), r.center().y), Align2::RIGHT_CENTER, format!("{q:.2}"), font(look::size::CAPTION), look::TEXT);
            }
            RateControl::Bitrate(m) => {
                text(ui, "Bitrate:", font(look::size::BODY), look::TEXT);
                if let Some(v) = number_field(ui, id.with("bitrate"), m, 64.0) {
                    out = Some(edit(move |s, _| s.set_bitrate_mbps(v)));
                }
                text(ui, "Mbps", font(look::size::CAPTION), look::SECONDARY);
            }
        }
    });
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 8.0;
        text(ui, "Keyframe interval:", font(look::size::BODY), look::TEXT);
        if let Some(v) = number_field(ui, id.with("keyframes"), f64::from(s.video.keyframe_interval), 56.0) {
            let frames = v.trunc() as i64;
            out = Some(edit(move |s, _| s.set_keyframe_interval(frames)));
        }
        text(ui, "frames (0 = auto)", font(look::size::CAPTION), look::SECONDARY);
    });
    if s.codec == OutputCodec::H264 {
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 8.0;
            text(ui, "Profile:", font(look::size::BODY), look::TEXT);
            popup_button(ui, logic::h264_profile_label(s.video.h264_profile), true, |ui| {
                for p in logic::H264_PROFILES {
                    if item(ui, logic::h264_profile_label(p), true) {
                        out = Some(edit(move |s, _| s.set_h264_profile(p)));
                    }
                }
            });
        });
    }
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 8.0;
        text(ui, "Container:", font(look::size::BODY), look::TEXT);
        popup_button(ui, s.container.label(), true, |ui| {
            if let Some(e) = container_items(ui, s.codec.allowed_containers()) {
                out = Some(e);
            }
        });
    });
    let note =
        if s.codec == OutputCodec::Hevc { "HEVC encodes opaque this version (alpha support is upcoming)." } else { "H.264 — the universal-delivery codec." };
    ui.add(egui::Label::new(RichText::new(note).font(font(look::size::CAPTION)).color(look::SECONDARY)).wrap());
    out
}

/// A popover (`.popover(isPresented:arrowEdge: .bottom)`) under `anchor`, 320 pt wide, padding 16, while `*open`.
/// Closes on Escape and on a click outside it (a click that only closes one of its own menus does not).
pub fn popover(ui: &Ui, id: Id, anchor: &Response, open: &mut bool, menu_was_open: bool, content: impl FnOnce(&mut Ui)) {
    if !*open {
        return;
    }
    let frame = egui::Frame::popup(ui.style()).fill(POPOVER).inner_margin(egui::Margin::same(16)).corner_radius(8);
    let shown =
        egui::Popup::from_response(anchor).id(id).open_bool(open).close_behavior(egui::PopupCloseBehavior::IgnoreClicks).width(320.0).frame(frame).show(|ui| {
            ui.set_width(288.0);
            ui.spacing_mut().item_spacing = vec2(8.0, 12.0);
            content(ui);
        });
    if let Some(r) = shown {
        let clicked_outside = ui.input(|i| i.pointer.any_click() && i.pointer.interact_pos().is_some_and(|p| !r.response.rect.contains(p)));
        if clicked_outside && !menu_was_open && !anchor.clicked() {
            *open = false;
        }
    }
}
