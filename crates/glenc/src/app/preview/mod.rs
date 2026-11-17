//! The preview pane (Swift GlEnc 1.6.2 `PreviewPane.swift`): the primary row's source or encoded output, played by
//! [`player`] and drawn through glance-gpu (the clip's Alpha Type a uniform), with the checkerboard behind clips
//! with real alpha (Preferences: "Fill viewport" / "Behind video only"), the crop overlay ([`overlay`]), the
//! transport (play / pause, previous / next frame, loop, set In, set Out, clear trim, the HH:MM:SS:FF readout) and
//! the scrub bar with In / Out ([`scrub`]).
//!
//! Keys, as Swift's `.keyboardShortcut`s / `.onKeyPress` have them: Space play / pause, ← / → previous / next frame
//! (released during a crop edit), I / O set In / Out; during a crop edit, with the pane focused (click into the
//! picture), arrows nudge the crop 4 px (⇧ 16 px) — the focused corner when one is, else the whole rectangle — and
//! Esc first clears a focused corner, then cancels the edit. None fire while a text field has focus, a sheet or the
//! collision prompt is up, or Preferences is open (Swift's sheets and separate Settings window keep them from the
//! main window).

pub mod crop;
pub mod overlay;
pub mod player;
pub mod scrub;
pub mod timecode;
pub mod trim;

use super::{UiState, look};
use crate::job::{JobId, PreviewSide, Status};
use crate::queue::Queue;
use crate::settings::CheckerboardScope;
use egui::{Color32, FontId, Key, Modifiers, Painter, Rect, Sense, Shape, Stroke, StrokeKind, pos2, vec2};
use glance_encode::frame::CropRect;
use glance_encode::source::AlphaType;
use glance_gpu::{ClipView, Presenter};
use glance_media::AlphaView;
use glance_ui::icons::{self, Icon};
use glance_ui::{Host, Picture};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use trim::Trim;

/// The transport's height: 8 + the button row + 6 + the scrub bar + 8 (`PreviewTransport`, `:454-556`).
const ROW: f32 = 18.0;
const TRANSPORT: f32 = 8.0 + ROW + 6.0 + scrub::HEIGHT + 8.0;

/// What the pane needs of the primary row this frame.
struct Row {
    id: JobId,
    status: Status,
    side: PreviewSide,
    source: PathBuf,
    /// `job.outputURL ?? job.defaultOutputURL`.
    output: PathBuf,
    output_available: bool,
    trim: Trim,
    crop: Option<CropRect>,
    alignment: i64,
    alpha_type: AlphaType,
}

impl Row {
    fn of(q: &Queue) -> Option<Row> {
        let j = q.selected_job()?;
        let output = j.output_path.clone().unwrap_or_else(|| j.default_output_path());
        // `outputAvailable` (`:124-128`): done, and the file is there.
        let output_available = j.status == Status::Done && output.exists();
        Some(Row {
            id: j.id,
            status: j.status,
            side: j.preview_side,
            source: j.source.clone(),
            output,
            output_available,
            trim: Trim::new(j.in_frame, j.out_frame),
            crop: j.crop,
            alignment: i64::from(j.settings.codec.dimension_alignment()),
            alpha_type: j.settings.alpha_type,
        })
    }

    /// The side the header shows (`effectivePreviewSide`, `:174-177`).
    fn effective_side(&self) -> PreviewSide {
        if self.side == PreviewSide::Output && self.output_available { PreviewSide::Output } else { PreviewSide::Source }
    }

    /// The file the area loads (`targetURL` + `loadIfNeeded`, `:221-226`, `:404-424`): none for a failed row, none
    /// for an output that is not there.
    fn target(&self) -> Option<PathBuf> {
        if self.status == Status::Failed {
            return None;
        }
        match self.side {
            PreviewSide::Source => Some(self.source.clone()),
            PreviewSide::Output => self.output.exists().then(|| self.output.clone()),
        }
    }
}

/// The preview pane.
#[derive(Default)]
pub struct Preview {
    player: player::Player,
    /// `loadKey` (`:231-233`): row, side, status.
    load_key: Option<(JobId, PreviewSide, Status)>,
    presenter: Option<Presenter>,
    view: Option<ClipView>,
    picture: Option<Picture>,
    drawn: Option<egui::load::SizedTexture>,
    /// (load generation, frame, Alpha Type) of the drawn picture.
    shown: Option<(u64, u32, AlphaView)>,
    /// The generation whose decode error was logged (once per clip).
    logged_error: Option<u64>,
    checker: Option<egui::TextureHandle>,
    scrub: scrub::Scrub,
    /// The thumb drag found the clip playing (`wasPlayingBeforeDrag`).
    scrub_resume: bool,
    overlay: overlay::Overlay,
    /// The pane holds keyboard focus (`previewFocused`): only during a crop edit, by clicking into the picture.
    focused: bool,
    /// The crop edit the focus and the focused corner belong to.
    crop_edit: Option<JobId>,
}

impl Preview {
    /// The pane is no longer drawn (⇧⌘P hid it): stop the clip and its sound (`.onDisappear { model.unload() }`).
    pub fn hidden(&mut self) {
        self.player.unload();
        self.load_key = None;
        self.drawn = None;
        self.shown = None;
        self.scrub.close();
    }

    pub fn show(&mut self, ui: &mut egui::Ui, host: &mut Host<'_>, q: &mut Queue, st: &mut UiState) {
        let pane = ui.max_rect();
        ui.painter().rect_filled(pane, 0.0, look::WINDOW);
        self.follow_crop_edit(q);
        let Some(row) = Row::of(q) else {
            self.hidden();
            empty_state(ui, pane);
            return;
        };
        self.load_if_needed(&row);
        self.keys(ui.ctx(), q, st, &row);
        let shown_at = Instant::now() + host.refresh_millihertz.map_or(Duration::from_millis(8), |mhz| Duration::from_secs_f64(1000.0 / f64::from(mhz.max(1))));
        self.player.advance(shown_at, row.trim);
        self.draw_frame(host, &row, shown_at);

        ui.spacing_mut().item_spacing = vec2(0.0, 0.0);
        self.header(ui, q, &row);
        let area_h = (ui.available_height() - TRANSPORT).max(0.0);
        let (area, resp) = ui.allocate_exact_size(vec2(ui.available_width(), area_h), Sense::click_and_drag());
        self.area(ui, &resp, area, pane, q, &row);
        self.transport(ui, q, &row);
        if let Some(a) = self.scrub.popover(ui.ctx(), self.player.fps(), self.player.total(), row.trim) {
            self.scrub_action(a, q, &row);
        }
    }

    /// The edit ended or moved: the focus and the focused corner go (`endCropEdit`).
    fn follow_crop_edit(&mut self, q: &Queue) {
        let now = q.crop_edit.map(|(id, _)| id);
        if now != self.crop_edit {
            self.crop_edit = now;
            self.focused = false;
            self.overlay.reset();
        }
    }

    fn load_if_needed(&mut self, row: &Row) {
        let key = (row.id, row.side, row.status);
        if self.load_key == Some(key) {
            return;
        }
        if self.load_key.is_some_and(|(id, ..)| id != row.id) {
            self.scrub.close();
        }
        self.load_key = Some(key);
        match row.target() {
            None => self.player.unload(),
            // Already that file: no restart (`:420-422`).
            Some(p) if self.player.path.as_deref() == Some(p.as_path()) => {}
            Some(p) => self.player.load(&p),
        }
    }

    fn draw_frame(&mut self, host: &mut Host<'_>, row: &Row, shown_at: Instant) {
        let generation = self.player.generation;
        let Some(l) = self.player.loaded.as_ref() else { return };
        let alpha = player::alpha_view(l.rule, row.side, row.alpha_type);
        let Some(result) = self.player.frame(shown_at) else { return };
        let shown = match result {
            Ok(s) => s,
            Err(e) => {
                if self.logged_error != Some(generation) {
                    self.logged_error = Some(generation);
                    eprintln!("[GlEnc/preview] decode error: {e}");
                }
                return;
            }
        };
        if self.shown == Some((generation, shown.index, alpha)) {
            return;
        }
        let presenter = self.presenter.get_or_insert_with(|| Presenter::new(&host.gpu.device));
        let view = self.view.get_or_insert_with(|| ClipView::new(&host.gpu.device));
        match view.show(host.gpu, presenter, &shown.frame, alpha) {
            Ok(t) => {
                let t = t.clone();
                self.drawn = Some(host.picture(&mut self.picture, &t));
                self.shown = Some((generation, shown.index, alpha));
            }
            Err(e) => {
                if self.logged_error != Some(generation) {
                    self.logged_error = Some(generation);
                    eprintln!("[GlEnc/preview] draw error: {e}");
                }
            }
        }
    }

    // MARK: - Keys

    fn keys(&mut self, ctx: &egui::Context, q: &mut Queue, st: &UiState, row: &Row) {
        if ctx.text_edit_focused() || st.sheet.is_some() || q.prompt.is_some() || st.prefs_open || self.scrub.popover_open() {
            return;
        }
        let playable = self.player.is_playable();
        let (current, total) = (self.player.current(), self.player.total());
        let editing = q.crop_edit.map(|(id, _)| id);
        let key = |k: Key, enabled: bool| enabled && ctx.input_mut(|i| i.consume_key(Modifiers::NONE, k));
        if key(Key::Space, playable) {
            self.player.toggle_pause(row.trim);
        }
        if key(Key::ArrowLeft, editing.is_none() && playable && current > 0) {
            self.player.step(-1);
        }
        if key(Key::ArrowRight, editing.is_none() && playable && current < total - 1) {
            self.player.step(1);
        }
        if key(Key::I, playable) {
            set_trim(q, row, row.trim.set_in_at(current));
        }
        if key(Key::O, playable) {
            set_trim(q, row, row.trim.set_out_at(current));
        }
        if editing.is_none() {
            return;
        }
        // Crop nudge (`handleCropNudge`, `:351-401`): this row's edit, the pane focused, a clip loaded.
        let dims = self.player.loaded.as_ref().map(|l| (i64::from(l.width), i64::from(l.height))).filter(|(w, h)| *w > 0 && *h > 0);
        if editing == Some(row.id)
            && self.focused
            && let Some((w, h)) = dims
        {
            for (k, dx, dy) in [(Key::ArrowUp, 0.0, -1.0), (Key::ArrowDown, 0.0, 1.0), (Key::ArrowLeft, -1.0, 0.0), (Key::ArrowRight, 1.0, 0.0)] {
                let shift = ctx.input_mut(|i| i.consume_key(Modifiers::SHIFT, k));
                if shift || ctx.input_mut(|i| i.consume_key(Modifiers::NONE, k)) {
                    let step = crop::nudge_step(shift);
                    let pending = q.crop_edit.and_then(|(_, r)| r).map(crop::Rect::from_crop);
                    let next = crop::nudge(pending, self.overlay.focused_corner, (dx * step, dy * step), w, h, row.alignment);
                    q.set_pending_crop(Some(next.to_crop()));
                }
            }
        }
        // Esc steps back (`:318-324`): a focused corner first, then the edit (the row's Cancel, `.cancelAction`).
        if ctx.input_mut(|i| i.consume_key(Modifiers::NONE, Key::Escape)) {
            if editing == Some(row.id) && self.focused && self.overlay.focused_corner.is_some() {
                self.overlay.focused_corner = None;
            } else {
                q.cancel_crop_edit();
            }
        }
    }

    // MARK: - Header

    /// File name and Source / Output (`PreviewHeader`, `:120-189`).
    fn header(&mut self, ui: &mut egui::Ui, q: &mut Queue, row: &Row) {
        let side = row.effective_side();
        let name_path = if side == PreviewSide::Output { &row.output } else { &row.source };
        let name = name_path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let subtitle = if side == PreviewSide::Output { "Encoded output" } else { "Source" };
        let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 46.0), Sense::hover());
        let p = ui.painter();
        p.rect_filled(rect, 0.0, look::LIST);
        let inner = rect.shrink2(vec2(12.0, 8.0));
        let picker = Rect::from_min_size(pos2(inner.right() - 140.0, inner.center().y - 11.0), vec2(140.0, 22.0));
        let name_font = FontId::proportional(12.0);
        let text_w = (picker.left() - 8.0 - inner.left()).max(0.0);
        let name = elide_middle(ui, &name, &name_font, text_w);
        let g = p.layout_no_wrap(name, name_font, look::TEXT);
        let sub = p.layout_no_wrap(subtitle.into(), FontId::proportional(10.0), look::SECONDARY);
        let top = inner.center().y - (g.size().y + 1.0 + sub.size().y) / 2.0;
        p.galley(pos2(inner.left(), top), g.clone(), look::TEXT);
        p.galley(pos2(inner.left(), top + g.size().y + 1.0), sub, look::SECONDARY);
        // The segmented picker, disabled until the output exists.
        let enabled = row.output_available;
        let resp = ui.interact(picker, egui::Id::new("glenc.preview.side"), if enabled { Sense::click() } else { Sense::hover() });
        let help = if enabled { "Toggle between source and encoded output" } else { "Output preview becomes available once encoding finishes" };
        let resp = resp.on_hover_text(help);
        let p = ui.painter();
        let dim = |c: Color32| if enabled { c } else { c.gamma_multiply(0.4) };
        p.rect_filled(picker, 5.0, look::BUTTON.gamma_multiply(0.45));
        let halves = [(PreviewSide::Source, "Source"), (PreviewSide::Output, "Output")];
        for (i, (s, label)) in halves.into_iter().enumerate() {
            let half = Rect::from_min_size(pos2(picker.left() + 70.0 * i as f32, picker.top()), vec2(70.0, 22.0));
            if s == side {
                p.rect_filled(half.shrink(2.0), 4.0, dim(look::BUTTON));
            }
            p.text(half.center(), egui::Align2::CENTER_CENTER, label, FontId::proportional(look::size::SMALL_CONTROL + 1.0), dim(look::TEXT));
        }
        if resp.clicked()
            && let Some(at) = resp.interact_pointer_pos()
        {
            let to = if at.x < picker.center().x { PreviewSide::Source } else { PreviewSide::Output };
            if to != row.side && (to == PreviewSide::Source || row.output_available) {
                q.set_preview_side(row.id, to);
            }
        }
    }

    // MARK: - Area

    /// The picture over black, the checkerboard behind a clip with alpha, the failure message, the crop overlay
    /// (`PreviewArea`, `:235-342`).
    fn area(&mut self, ui: &mut egui::Ui, resp: &egui::Response, area: Rect, pane: Rect, q: &mut Queue, row: &Row) {
        let painter = ui.painter_at(area);
        painter.rect_filled(area, 0.0, Color32::BLACK);
        let editing_this = q.crop_edit.is_some_and(|(id, _)| id == row.id);
        // The pane takes focus from a click into the picture while this row is being cropped; a click outside the
        // pane takes it away (`.focusable(isCropEditing)`).
        if let Some(o) = ui.input(|i| if i.pointer.primary_pressed() { i.pointer.press_origin() } else { None }) {
            if editing_this && area.contains(o) && resp.contains_pointer() {
                self.focused = true;
            } else if !pane.contains(o) || !editing_this {
                self.focused = false;
            }
        }
        let Some(l) = self.player.loaded.as_ref() else {
            if let Some(msg) = &self.player.failure {
                failure(&painter, area, msg);
            }
            return;
        };
        let (w, h) = (i64::from(l.width), i64::from(l.height));
        let bounds = crop::Rect::new(f64::from(area.left()), f64::from(area.top()), f64::from(area.width()), f64::from(area.height()));
        let fit = crop::AspectFit::new(w, h, bounds);
        let values = q.settings.values();
        if l.has_alpha {
            let behind = values.checkerboard_scope == CheckerboardScope::BehindVideoOnly;
            let r = crop::checkerboard_frame(behind, w, h, bounds);
            let r = Rect::from_min_size(pos2(r.x as f32, r.y as f32), vec2(r.w as f32, r.h as f32));
            let checker = self.checker.get_or_insert_with(|| checker_texture(ui.ctx()));
            let uv = Rect::from_min_size(pos2(0.0, 0.0), r.size() / (2.0 * glance_ui::CHECKER_CELL));
            painter.image(checker.id(), r, uv, Color32::WHITE);
        }
        if let (Some(d), Some((generation, ..))) = (self.drawn, self.shown)
            && generation == self.player.generation
        {
            let f = fit.fitted;
            let r = Rect::from_min_size(pos2(f.x as f32, f.y as f32), vec2(f.w as f32, f.h as f32));
            painter.image(d.id, r, Rect::from_min_max(pos2(0.0, 0.0), pos2(1.0, 1.0)), Color32::WHITE);
        }
        if w <= 0 || h <= 0 {
            return;
        }
        // The overlay is mounted once a clip is loaded (`:275-293`).
        let pending = q.crop_edit.filter(|(id, _)| *id == row.id).map(|(_, r)| r);
        let bound = match pending {
            Some(p) => p,
            None => row.crop,
        };
        let rect = bound.map(crop::Rect::from_crop).or_else(|| editing_this.then(|| crop::full_frame_seed_rect(w, h, row.alignment)));
        let input = overlay::Input {
            fit,
            rect,
            active: editing_this,
            dim: q.crop_edit.is_none() && row.crop.is_some(),
            boundary: values.show_clip_boundary,
            focused: self.focused,
            alignment: row.alignment,
        };
        if let Some(next) = self.overlay.show(ui, resp, &input) {
            q.set_pending_crop(Some(next.to_crop()));
        }
    }

    // MARK: - Transport

    /// Two rows: the buttons and readout, then the scrub bar at full width (`PreviewTransport`, `:449-557`).
    fn transport(&mut self, ui: &mut egui::Ui, q: &mut Queue, row: &Row) {
        let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), TRANSPORT), Sense::hover());
        ui.painter().rect_filled(rect, 0.0, look::LIST);
        let inner = rect.shrink2(vec2(12.0, 8.0));
        let mut child = ui.new_child(egui::UiBuilder::new().max_rect(inner).layout(egui::Layout::top_down(egui::Align::Min)));
        child.spacing_mut().item_spacing = vec2(10.0, 6.0);
        let playable = self.player.is_playable();
        let playing = self.player.is_playing();
        let (current, total) = (self.player.current(), self.player.total());
        let trim = row.trim;
        child.allocate_ui_with_layout(vec2(inner.width(), ROW), egui::Layout::left_to_right(egui::Align::Center), |ui| {
            let ic = |p: &Painter, r: Rect, i: Icon, c: Color32| icons::draw(p, r, i, c);
            let help = if playing { "Pause (Space)" } else { "Play (Space)" };
            if icon_button(ui, playable, help, look::TEXT, |p, r, c| ic(p, r, if playing { Icon::Pause } else { Icon::Play }, c)) {
                self.player.toggle_pause(trim);
            }
            if icon_button(ui, playable && current > 0, "Previous frame (←)", look::TEXT, |p, r, c| ic(p, r, Icon::StepBack, c)) {
                self.player.step(-1);
            }
            if icon_button(ui, playable && current < total - 1, "Next frame (→)", look::TEXT, |p, r, c| ic(p, r, Icon::StepForward, c)) {
                self.player.step(1);
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let has_trim = trim.is_set();
                if icon_button(ui, playable && has_trim, "Clear trim (encode full clip)", look::SECONDARY, trash) {
                    set_trim(q, row, Trim::default());
                }
                if icon_button(ui, playable, "Set out-point at current frame (O)", look::ACCENT, |p, r, c| arrowhead(p, r, -1.0, c)) {
                    set_trim(q, row, trim.set_out_at(current));
                }
                if icon_button(ui, playable, "Set in-point at current frame (I)", look::ACCENT, |p, r, c| arrowhead(p, r, 1.0, c)) {
                    set_trim(q, row, trim.set_in_at(current));
                }
                let (d, _) = ui.allocate_exact_size(vec2(1.0, 16.0), Sense::hover());
                ui.painter().rect_filled(d, 0.0, look::SEPARATOR);
                let looping = self.player.looping;
                let (help, color) = if looping {
                    ("Loop on — playback wraps at end. Click to disable.", look::ACCENT)
                } else {
                    ("Loop off — playback stops at end. Click to enable.", look::SECONDARY)
                };
                if icon_button(ui, playable, help, color, |p, r, c| loop_icon(p, r, looping, c)) {
                    self.player.set_looping(!looping);
                }
                // The readout, centred between the two groups.
                let label = if playable {
                    let fps = self.player.fps();
                    format!("{} / {}", timecode::string(current, fps), timecode::string((total - 1).max(0), fps))
                } else {
                    "—".into()
                };
                let (r, _) = ui.allocate_exact_size(vec2(ui.available_width(), ROW), Sense::hover());
                ui.painter().text(r.center(), egui::Align2::CENTER_CENTER, label, FontId::monospace(11.0), look::SECONDARY);
            });
        });
        for a in self.scrub.bar(&mut child, playable, current, total, trim) {
            self.scrub_action(a, q, row);
        }
    }

    fn scrub_action(&mut self, a: scrub::Action, q: &mut Queue, row: &Row) {
        match a {
            scrub::Action::BeginScrub => {
                self.scrub_resume = self.player.is_playing();
                self.player.pause();
            }
            scrub::Action::Seek(f) => {
                if f != self.player.current() {
                    self.player.seek(f);
                }
            }
            scrub::Action::EndScrub => {
                if std::mem::take(&mut self.scrub_resume) {
                    self.player.play(row.trim);
                }
            }
            scrub::Action::SetIn(f) => set_trim(q, row, Trim { in_frame: Some(f), ..row.trim }),
            scrub::Action::SetOut(f) => set_trim(q, row, Trim { out_frame: Some(f), ..row.trim }),
        }
    }
}

/// Write the row's trim when it changed (`syncModelTrimToJob`, `:86-103`; the queue refreshes the auto name).
fn set_trim(q: &mut Queue, row: &Row, t: Trim) {
    if t != row.trim {
        q.set_trim(row.id, t.in_frame, t.out_frame);
    }
}

/// `emptyState` (`:105-115`): `play.rectangle` at 48 pt, light, secondary at 40 %, and the line under it.
fn empty_state(ui: &egui::Ui, pane: Rect) {
    let p = ui.painter();
    let c = pane.center();
    let icon = Rect::from_center_size(pos2(c.x, c.y - 20.0), vec2(56.0, 42.0));
    let color = look::SECONDARY.gamma_multiply(0.4);
    p.rect_stroke(icon, 8.0, Stroke::new(1.5, color), StrokeKind::Middle);
    let t = icon.center();
    p.add(Shape::convex_polygon(vec![pos2(t.x - 6.0, t.y - 8.0), pos2(t.x + 9.0, t.y), pos2(t.x - 6.0, t.y + 8.0)], color, Stroke::NONE));
    p.text(
        pos2(c.x, icon.bottom() + 8.0),
        egui::Align2::CENTER_TOP,
        "Select a queue row to preview",
        FontId::proportional(look::size::CALLOUT),
        look::SECONDARY,
    );
}

/// `.failed(msg)` (`:246-256`): an orange warning triangle over the message.
fn failure(p: &Painter, area: Rect, msg: &str) {
    let c = area.center();
    let t = Rect::from_center_size(pos2(c.x, c.y - 14.0), vec2(24.0, 22.0));
    p.add(Shape::closed_line(vec![pos2(t.center().x, t.top()), pos2(t.right(), t.bottom()), pos2(t.left(), t.bottom())], Stroke::new(1.8, look::ORANGE)));
    p.line_segment([pos2(t.center().x, t.top() + 8.0), pos2(t.center().x, t.bottom() - 7.0)], Stroke::new(1.8, look::ORANGE));
    p.circle_filled(pos2(t.center().x, t.bottom() - 3.5), 1.1, look::ORANGE);
    let g = p.layout(msg.into(), FontId::proportional(look::size::CALLOUT), look::SECONDARY, (area.width() - 48.0).max(10.0));
    p.galley(pos2(c.x - g.size().x / 2.0, t.bottom() + 6.0), g, look::SECONDARY);
}

/// The checkerboard as a repeating 2 × 2 texture: glance-ui's `Checker` (its squares and greys), drawable over any
/// rect (Swift's "Fill viewport" reaches past the picture, which `glance_ui::video` does not).
fn checker_texture(ctx: &egui::Context) -> egui::TextureHandle {
    let [light, dark] = glance_ui::CHECKER_GREYS.map(Color32::from_gray);
    let image = egui::ColorImage::new([2, 2], vec![light, dark, dark, light]);
    let options = egui::TextureOptions { wrap_mode: egui::TextureWrapMode::Repeat, ..egui::TextureOptions::NEAREST };
    ctx.load_texture("glenc-preview-checker", image, options)
}

/// A borderless 22 × 18 icon button (`.buttonStyle(.borderless)`); disabled is dimmed and inert.
fn icon_button(ui: &mut egui::Ui, enabled: bool, help: &str, color: Color32, draw: impl FnOnce(&Painter, Rect, Color32)) -> bool {
    let (r, resp) = ui.allocate_exact_size(vec2(22.0, ROW), if enabled { Sense::click() } else { Sense::hover() });
    let c = if !enabled {
        color.gamma_multiply(0.35)
    } else if resp.is_pointer_button_down_on() {
        color.gamma_multiply(0.6)
    } else {
        color
    };
    draw(ui.painter(), r, c);
    enabled && resp.on_hover_text(help).clicked()
}

/// `arrowtriangle.right.fill` (dir 1) / `arrowtriangle.left.fill` (dir -1) at 12 pt.
fn arrowhead(p: &Painter, r: Rect, dir: f32, c: Color32) {
    let m = r.center();
    let (tip, base) = (m.x + dir * 4.5, m.x - dir * 4.5);
    p.add(Shape::convex_polygon(vec![pos2(base, m.y - 5.0), pos2(tip, m.y), pos2(base, m.y + 5.0)], c, Stroke::NONE));
}

/// `trash` at 12 pt.
fn trash(p: &Painter, r: Rect, c: Color32) {
    let m = r.center();
    let s = Stroke::new(1.2, c);
    p.line_segment([pos2(m.x - 5.0, m.y - 3.5), pos2(m.x + 5.0, m.y - 3.5)], s);
    p.add(Shape::line(vec![pos2(m.x - 1.8, m.y - 3.5), pos2(m.x - 1.8, m.y - 5.5), pos2(m.x + 1.8, m.y - 5.5), pos2(m.x + 1.8, m.y - 3.5)], s));
    p.add(Shape::line(vec![pos2(m.x - 3.8, m.y - 3.5), pos2(m.x - 3.0, m.y + 5.5), pos2(m.x + 3.0, m.y + 5.5), pos2(m.x + 3.8, m.y - 3.5)], s));
    p.line_segment([pos2(m.x, m.y - 1.5), pos2(m.x, m.y + 3.5)], Stroke::new(0.9, c));
}

/// `repeat` when looping, `repeat.1` when not.
fn loop_icon(p: &Painter, r: Rect, looping: bool, c: Color32) {
    icons::draw(p, r, Icon::Loop, c);
    if !looping {
        p.text(r.center(), egui::Align2::CENTER_CENTER, "1", FontId::proportional(6.5), c);
    }
}

/// `.truncationMode(.middle)`: the name with its middle replaced by "…" until it fits `max_w`.
fn elide_middle(ui: &egui::Ui, text: &str, font: &FontId, max_w: f32) -> String {
    let width = |s: &str| ui.painter().layout_no_wrap(s.to_string(), font.clone(), Color32::WHITE).size().x;
    if width(text) <= max_w {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    let mut keep = chars.len();
    while keep > 0 {
        keep -= 1;
        let (head, tail) = (keep.div_ceil(2), keep / 2);
        let s: String = chars[..head].iter().chain(std::iter::once(&'…')).chain(chars[chars.len() - tail..].iter()).collect();
        if width(&s) <= max_w {
            return s;
        }
    }
    "…".into()
}
