//! The queue column (Swift GlEnc 1.6.2 `ContentView.swift:57-256`): the settings bar (padding 12 / 8 / 4), the drop
//! zone (130 pt, dashed rounded border, padding 12 / 4 / 8), a divider, the header ("N jobs", the overall progress
//! up to 220 pt and its percentage, Select All / Select One, Reset Finished, Clear Completed), then "No jobs queued."
//! or the list of rows: plain click selects one, ⌘-click toggles, ⇧-click extends; a divider under each row; the
//! right-click menu "Reset for Re-run".

#[path = "rows_kit.rs"]
pub mod rows_kit;
#[path = "rows_logic.rs"]
pub mod rows_logic;

use super::UiState;
use super::look;
use crate::job::JobId;
use crate::queue::Queue;
use egui::{Align, Align2, Color32, Layout, Margin, Pos2, Rect, Sense, Shape, Stroke, Ui, UiBuilder, pos2, vec2};
use glance_encode::frame::CropRect;
use rows_kit as kit;
use rows_logic as logic;
use std::collections::HashMap;

/// Who owns the open Advanced popover.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Owner {
    Bar,
    Row(JobId),
}

/// The crop fields of the row being crop-edited (`JobCardView`'s `@State` for them).
#[derive(Debug)]
pub struct CropFields {
    /// The row the texts belong to.
    pub job: Option<JobId>,
    pub texts: [String; 4],
    /// The focused field (`@FocusState focusedCropField`).
    pub focus: Option<logic::CropField>,
    /// The focused field's text when it gained focus (`cropFieldBaseline`).
    pub baseline: String,
    /// When each field's orange flash started (seconds of `ui.input().time`).
    pub flash: [f64; 4],
    /// The in-flight rectangle the texts were last synced from.
    pub last_pending: Option<CropRect>,
}

impl Default for CropFields {
    fn default() -> CropFields {
        CropFields { job: None, texts: Default::default(), focus: None, baseline: String::new(), flash: [f64::NEG_INFINITY; 4], last_pending: None }
    }
}

/// This module's own UI state (the rows, the settings bar and the queue column).
#[derive(Debug, Default)]
pub struct RowsState {
    /// The ⇧-click anchor.
    pub anchor: Option<JobId>,
    /// The open Advanced popover.
    pub advanced: Option<Owner>,
    /// A menu was open when this frame began (a click then only closes it).
    pub menu_was_open: bool,
    pub crop: CropFields,
    /// Who states each row's alpha ("HAP", "ProRes 4444", …), read once from the file.
    pub stated_by: HashMap<JobId, String>,
}

pub fn queue_column(ui: &mut Ui, q: &mut Queue, st: &mut UiState) {
    st.rows.menu_was_open = egui::Popup::is_any_open(ui.ctx());
    ui.painter().rect_filled(ui.max_rect(), 0.0, look::WINDOW);
    ui.spacing_mut().item_spacing = vec2(0.0, 0.0);
    egui::Frame::NONE.inner_margin(Margin { left: 12, right: 12, top: 8, bottom: 4 }).show(ui, |ui| {
        ui.set_width(ui.available_width());
        super::bar::show(ui, q, st);
    });
    egui::Frame::NONE.inner_margin(Margin { left: 12, right: 12, top: 4, bottom: 8 }).show(ui, |ui| {
        ui.set_width(ui.available_width());
        drop_zone(ui, st);
    });
    divider(ui);
    egui::Frame::NONE.inner_margin(Margin::symmetric(12, 8)).show(ui, |ui| {
        ui.set_width(ui.available_width());
        header(ui, q);
    });
    if q.jobs.is_empty() {
        empty_state(ui);
    } else {
        rows(ui, q, st);
    }
    // Rows that left the queue take their cached details with them.
    st.rows.stated_by.retain(|id, _| q.jobs.iter().any(|j| j.id == *id));
}

/// `Divider()`: a 1-pt separator line across the column.
fn divider(ui: &mut Ui) {
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 1.0), Sense::hover());
    ui.painter().rect_filled(rect, 0.0, look::SEPARATOR);
}

// MARK: - Drop zone

fn drop_zone(ui: &mut Ui, st: &mut UiState) {
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 130.0), Sense::hover());
    st.drop_zone = Some(rect);
    let targeted = ui.input(|i| !i.raw.hovered_files.is_empty() && i.pointer.latest_pos().is_none_or(|p| rect.contains(p)));
    let p = ui.painter();
    p.rect_filled(rect, 10.0, if targeted { kit::DROP_FILL_TARGETED } else { kit::DROP_FILL });
    // `.strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))`: inside the edge.
    let path = rounded_rect_path(rect.shrink(1.0), 9.0);
    let stroke = Stroke::new(2.0, if targeted { look::ACCENT } else { kit::DROP_STROKE });
    p.extend(Shape::dashed_line(&path, stroke, 6.0, 4.0));
    let fg = if targeted { look::ACCENT } else { look::SECONDARY };
    let headline = kit::semibold(look::size::HEADLINE);
    let caption = kit::font(look::size::CAPTION);
    let (icon_h, head_h, cap_h, gap) = (28.0, 16.0, 13.0, 6.0);
    let top = rect.center().y - (icon_h + head_h + cap_h + 2.0 * gap) / 2.0;
    kit::tray_arrow_down(p, pos2(rect.center().x, top + icon_h / 2.0), 28.0, fg);
    p.text(pos2(rect.center().x, top + icon_h + gap + head_h / 2.0), Align2::CENTER_CENTER, "Drop video files to queue", headline, fg);
    p.text(
        pos2(rect.center().x, top + icon_h + head_h + 2.0 * gap + cap_h / 2.0),
        Align2::CENTER_CENTER,
        ".mov  .mp4  .m4v  .qt  (anything public.movie)",
        caption,
        look::SECONDARY,
    );
}

/// A closed rounded-rectangle outline as points.
fn rounded_rect_path(r: Rect, radius: f32) -> Vec<Pos2> {
    let corner = |c: Pos2, a0: f32| {
        (0..=8).map(move |i| a0 + std::f32::consts::FRAC_PI_2 * i as f32 / 8.0).map(move |a| pos2(c.x + radius * a.cos(), c.y + radius * a.sin()))
    };
    let pi = std::f32::consts::PI;
    let mut pts: Vec<Pos2> = Vec::new();
    pts.extend(corner(pos2(r.right() - radius, r.top() + radius), -pi / 2.0));
    pts.extend(corner(pos2(r.right() - radius, r.bottom() - radius), 0.0));
    pts.extend(corner(pos2(r.left() + radius, r.bottom() - radius), pi / 2.0));
    pts.extend(corner(pos2(r.left() + radius, r.top() + radius), pi));
    if let Some(&first) = pts.first() {
        pts.push(first);
    }
    pts
}

// MARK: - Header

fn header(ui: &mut Ui, q: &mut Queue) {
    let n = q.jobs.len();
    let small = kit::font(look::size::SMALL_CONTROL);
    let mut right: Vec<&str> = Vec::new();
    if n >= 2 {
        right.push(if q.selected_ids.len() == n { "Select One" } else { "Select All" });
    }
    let finished = q.has_finished();
    if finished {
        right.extend(["Reset Finished", "Clear Completed"]);
    }
    let right_w: f32 = right.iter().map(|l| kit::width_of(ui, l, &small) + 16.0 + 12.0).sum();
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 12.0;
        ui.set_min_height(18.0);
        kit::text(ui, logic::jobs_label(n), kit::font(look::size::CALLOUT), look::SECONDARY);
        if let Some(p) = q.overall_progress() {
            let pct = logic::percent(p);
            let pct_w = kit::width_of(ui, &pct, &kit::mono(look::size::CAPTION));
            let bar = (ui.available_width() - right_w - pct_w - 12.0 - 8.0).clamp(0.0, 220.0);
            kit::progress_bar(ui, bar, p);
            kit::text(ui, pct, kit::mono(look::size::CAPTION), look::SECONDARY);
        }
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            ui.spacing_mut().item_spacing.x = 12.0;
            if finished {
                if kit::small_button(ui, "Clear Completed", true, false).clicked() {
                    q.clear_completed();
                }
                let r = kit::small_button(ui, "Reset Finished", !q.is_encoding(), false);
                let r =
                    kit::help(r, "Queue every finished clip again with its current settings (⇧⌘R). Existing outputs are kept; re-runs write name_2, name_3, …");
                if r.clicked() {
                    q.reset_all_finished();
                }
            }
            if n >= 2 {
                if q.selected_ids.len() == n {
                    let r = kit::help(kit::small_button(ui, "Select One", true, false), "Back to a single clip — the top bar edits the defaults again.");
                    if r.clicked() {
                        q.collapse_to_primary();
                    }
                } else {
                    let r = kit::help(kit::small_button(ui, "Select All", true, false), "Select every clip so the top bar edits them all (⇧⌘A).");
                    if r.clicked() {
                        q.select_all();
                    }
                }
            }
        });
    });
}

fn empty_state(ui: &mut Ui) {
    let h = ui.available_height().max(120.0);
    let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), h), Sense::hover());
    ui.painter().text(rect.center(), Align2::CENTER_CENTER, "No jobs queued.", kit::font(look::size::CALLOUT), look::SECONDARY);
}

// MARK: - Rows

fn rows(ui: &mut Ui, q: &mut Queue, st: &mut UiState) {
    egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
        ui.spacing_mut().item_spacing = vec2(0.0, 0.0);
        let ids: Vec<JobId> = q.jobs.iter().map(|j| j.id).collect();
        for id in ids {
            if q.job(id).is_some() {
                row(ui, q, st, id, &order(q));
            }
        }
    });
}

fn order(q: &Queue) -> Vec<JobId> {
    q.jobs.iter().map(|j| j.id).collect()
}

fn row(ui: &mut Ui, q: &mut Queue, st: &mut UiState, id: JobId, order: &[JobId]) {
    let builder = UiBuilder::new().id_salt(("glenc-row", id)).sense(Sense::click()).layout(Layout::top_down(Align::Min));
    let resp = ui
        .scope_builder(builder, |ui| {
            ui.set_width(ui.available_width());
            let bg = ui.painter().add(Shape::Noop);
            super::card::show(ui, q, st, id);
            divider(ui);
            if q.selected_ids.contains(&id) {
                let r = ui.min_rect();
                ui.painter().set(bg, Shape::rect_filled(Rect::from_min_max(r.min, pos2(r.max.x, r.max.y - 1.0)), 0.0, look::SELECTED_ROW));
            }
        })
        .response;
    if resp.clicked() {
        let (command, shift) = ui.input(|i| (i.modifiers.command, i.modifiers.shift));
        let (set, anchor) = logic::click_selection(order, &q.selected_ids, st.rows.anchor, id, command, shift);
        st.rows.anchor = anchor;
        if !command && !shift {
            q.select_one(id);
        } else {
            q.select(set);
        }
    }
    egui::Popup::context_menu(&resp).frame(kit::menu_frame(ui)).show(|ui| {
        kit::menu_look(ui);
        let targets = logic::context_targets(&q.selected_ids, id);
        let enabled = logic::reset_enabled(&q.jobs, &targets, q.is_encoding());
        if kit::item(ui, "Reset for Re-run", enabled) {
            q.reset_jobs(&targets);
        }
    });
}

/// A colour at `alpha` (0…1) over nothing.
pub fn faded(c: Color32, alpha: f32) -> Color32 {
    c.gamma_multiply(alpha)
}
