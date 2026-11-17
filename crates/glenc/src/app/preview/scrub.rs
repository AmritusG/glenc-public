//! The scrub bar (Swift `ScrubBar.swift`): "the timeline is the trim". The playhead thumb is the only way to seek;
//! a press anywhere else on the bar moves In (left half) or Out (right half), the half locked at the press so a drag
//! across the middle never switches sides; a double-click opens the HH:MM:SS:FF popover for that side
//! (`TimecodePopover.swift`).

use super::timecode;
use super::trim::{self, Trim};
use crate::app::look;
use egui::{Color32, FontId, Key, Pos2, Sense, Stroke, pos2, vec2};

const TRACK: f32 = 8.0;
const THUMB: f32 = 14.0;
const THUMB_HIT: f32 = 24.0;
/// The bar's interactive height (taller than the track, `:33`).
pub const HEIGHT: f32 = 28.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    In,
    Out,
}

/// What the bar asks of the pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// A thumb drag began: pause, remembering whether it played.
    BeginScrub,
    Seek(i64),
    /// The thumb drag ended: play again if it played.
    EndScrub,
    SetIn(i64),
    SetOut(i64),
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Playhead,
    Trim(Side),
}

struct Popover {
    side: Side,
    /// Filled on the popover's first frame from the row's trim then (`onAppear`).
    text: Option<String>,
    error: Option<String>,
    bar: egui::Rect,
    opened_pass: u64,
    last_rect: Option<egui::Rect>,
}

/// The bar's state between frames.
#[derive(Default)]
pub struct Scrub {
    mode: Option<Mode>,
    popover: Option<Popover>,
}

impl Scrub {
    pub fn popover_open(&self) -> bool {
        self.popover.is_some()
    }

    pub fn close(&mut self) {
        self.popover = None;
        self.mode = None;
    }

    /// The bar, full width. `enabled` is "a clip is loaded" (`.disabled(!isPlayable)`).
    pub fn bar(&mut self, ui: &mut egui::Ui, enabled: bool, current: i64, total: i64, trim: Trim) -> Vec<Action> {
        let (rect, resp) = ui.allocate_exact_size(vec2(ui.available_width(), HEIGHT), if enabled { Sense::click_and_drag() } else { Sense::hover() });
        let w = rect.width();
        let p = ui.painter();
        let track = egui::Rect::from_center_size(rect.center(), vec2(w, TRACK));
        p.rect_filled(track, 2.0, look::SECONDARY.gamma_multiply(0.3));
        let mut actions = Vec::new();
        if !enabled {
            self.mode = None;
            return actions;
        }
        let in_x = trim::x_for_frame(trim.in_frame.unwrap_or(0), w, total);
        let out_x = trim::x_for_frame(trim.out_frame.unwrap_or((total - 1).max(0)), w, total);
        let thumb = pos2(rect.left() + trim::x_for_frame(current, w, total), rect.center().y);
        if total > 1 {
            let region = egui::Rect::from_min_size(pos2(rect.left() + in_x, track.top()), vec2((out_x - in_x).max(0.0), TRACK));
            p.rect_filled(region, 2.0, look::ACCENT.gamma_multiply(0.5));
            p.circle_filled(thumb + vec2(0.0, 0.5), THUMB / 2.0 + 0.5, Color32::from_black_alpha(60));
            p.circle_filled(thumb, THUMB / 2.0, Color32::WHITE);
            p.circle_stroke(thumb, THUMB / 2.0, Stroke::new(0.5, look::SECONDARY.gamma_multiply(0.6)));
        }
        let (pressed, down, origin, at) =
            ui.input(|i| (i.pointer.primary_pressed(), i.pointer.primary_down(), i.pointer.press_origin(), i.pointer.interact_pos()));
        if pressed
            && let Some(o) = origin
            && rect.contains(o)
            && resp.contains_pointer()
            && total > 1
        {
            // The thumb's circle wins; everywhere else is the trim gesture, its half fixed now (`:127-146`).
            if o.distance(thumb) <= THUMB_HIT / 2.0 {
                self.mode = Some(Mode::Playhead);
                actions.push(Action::BeginScrub);
            } else {
                self.mode = Some(Mode::Trim(if o.x - rect.left() < w / 2.0 { Side::In } else { Side::Out }));
            }
        }
        match (self.mode, at) {
            (Some(_), _) if !down => {
                if self.mode == Some(Mode::Playhead) {
                    actions.push(Action::EndScrub);
                }
                self.mode = None;
            }
            (Some(mode), Some(at)) => {
                let target = trim::frame_for_x(at.x - rect.left(), w, total);
                actions.push(match mode {
                    Mode::Playhead => Action::Seek(target),
                    Mode::Trim(Side::In) => Action::SetIn(trim.dragged_in(target, total)),
                    Mode::Trim(Side::Out) => Action::SetOut(trim.dragged_out(target, total)),
                });
            }
            _ => {}
        }
        if resp.double_clicked()
            && let Some(at) = resp.interact_pointer_pos()
        {
            let side = if at.x - rect.left() < w / 2.0 { Side::In } else { Side::Out };
            self.popover = Some(Popover { side, text: None, error: None, bar: rect, opened_pass: ui.ctx().cumulative_pass_nr(), last_rect: None });
        }
        actions
    }

    /// The In / Out popover, when open: Return or Set commits, Esc or Cancel (or a click outside) closes.
    pub fn popover(&mut self, ctx: &egui::Context, fps: f64, total: i64, trim: Trim) -> Option<Action> {
        let pop = self.popover.as_mut()?;
        let title = match pop.side {
            Side::In => "Set in-point",
            Side::Out => "Set out-point",
        };
        let field_id = egui::Id::new(("glenc.preview.timecode", pop.side == Side::In));
        let first = pop.text.is_none();
        let text = pop.text.get_or_insert_with(|| {
            let initial = match pop.side {
                Side::In => trim.in_frame.unwrap_or(0),
                Side::Out => trim.out_frame.unwrap_or((total - 1).max(0)),
            };
            timecode::string(initial, fps)
        });
        let size = pop.last_rect.map_or(vec2(240.0, 132.0), |r| r.size());
        let screen = ctx.content_rect();
        let x = (pop.bar.center().x - size.x / 2.0).clamp(screen.left() + 4.0, (screen.right() - size.x - 4.0).max(screen.left() + 4.0));
        let below = pop.bar.bottom() + 8.0;
        let y = if below + size.y <= screen.bottom() { below } else { pop.bar.top() - 8.0 - size.y };
        let (mut set, mut cancel) = (false, false);
        let shown = egui::Area::new(egui::Id::new("glenc.preview.timecode-popover")).order(egui::Order::Foreground).fixed_pos(pos2(x, y)).show(ctx, |ui| {
            egui::Frame::popup(ui.style()).inner_margin(16.0).show(ui, |ui| {
                ui.set_min_width(240.0 - 32.0);
                ui.spacing_mut().item_spacing.y = 10.0;
                ui.label(egui::RichText::new(title).size(look::size::HEADLINE).strong());
                let field = ui
                    .add(egui::TextEdit::singleline(text).id(field_id).hint_text("HH:MM:SS:FF").font(FontId::monospace(look::size::BODY)).desired_width(130.0));
                if first {
                    field.request_focus();
                }
                match &pop.error {
                    Some(e) => ui.label(egui::RichText::new(e).size(look::size::CAPTION).color(look::RED)),
                    None => ui.label(egui::RichText::new(timecode::caption(fps, total)).size(look::size::CAPTION).color(look::SECONDARY)),
                };
                ui.horizontal(|ui| {
                    cancel |= ui.button("Cancel").clicked();
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        let ok = egui::Button::new(egui::RichText::new("Set").color(Color32::WHITE)).fill(look::ACCENT);
                        set |= ui.add_enabled(fps > 0.0, ok).clicked();
                    });
                });
            });
        });
        let rect = shown.response.rect;
        pop.last_rect = Some(rect);
        let (enter, esc) = ctx.input_mut(|i| (i.consume_key(egui::Modifiers::NONE, Key::Enter), i.consume_key(egui::Modifiers::NONE, Key::Escape)));
        let outside = ctx.input(|i| i.pointer.primary_pressed() && i.pointer.interact_pos().is_some_and(|p: Pos2| !rect.contains(p)));
        if esc || cancel || (outside && ctx.cumulative_pass_nr() > pop.opened_pass) {
            self.popover = None;
            return None;
        }
        if !(set || enter) {
            return None;
        }
        match timecode::commit(text, fps, total) {
            Ok(frame) => {
                // The popover's clamp (`ScrubBar.swift:95-101`, `:111-117`).
                let action = match pop.side {
                    Side::In => Action::SetIn(trim.dragged_in(frame, total)),
                    Side::Out => Action::SetOut(trim.dragged_out(frame, total)),
                };
                self.popover = None;
                Some(action)
            }
            Err(e) => {
                pop.error = Some(e);
                ctx.memory_mut(|m| m.request_focus(field_id));
                None
            }
        }
    }
}
