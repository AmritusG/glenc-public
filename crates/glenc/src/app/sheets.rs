//! The sheets over the window (Swift GlEnc 1.6.2): the output collision prompt (`CollisionPromptView.swift`,
//! `CollisionPrompt.swift`), the Custom output size sheet (`ResizeCustomSheet.swift`) and Manage saved sizes
//! (`ManageSizesSheet.swift`). Swift's sheets hang from the window's title bar; these are egui modals centred over
//! the window, with a dimmed backdrop that takes no clicks (a sheet is dismissed by its buttons only).

pub mod kit;

use super::{Sheet, UiState, look};
use crate::job::JobId;
use crate::json::NamedSize;
use crate::queue::{CollisionDecision, Queue};
use crate::settings::Settings;
use egui::{Align, Color32, Id, Layout, RichText, vec2};
use glance_encode::size::OutputSize;

/// This module's own UI state.
#[derive(Default)]
pub struct SheetsState {
    /// The Custom size sheet has been set up (its fields filled, the width field focused) since it opened.
    custom_ready: bool,
}

/// Draw whichever sheet is up. The collision prompt goes last, so it is on top if it arrives over another sheet.
pub fn show(ctx: &egui::Context, q: &mut Queue, st: &mut UiState) {
    match st.sheet {
        Some(Sheet::CustomSize { .. }) => custom_size(ctx, q, st),
        Some(Sheet::ManageSizes) => manage_sizes(ctx, &mut q.settings, st),
        None => {}
    }
    if !matches!(st.sheet, Some(Sheet::CustomSize { .. })) {
        st.sheets.custom_ready = false;
    }
    if q.prompt.is_some() {
        collision_prompt(ctx, q, st);
    }
}

fn modal(ctx: &egui::Context, id: &str, width: f32, content: impl FnOnce(&mut egui::Ui)) {
    egui::Modal::new(Id::new(id)).frame(kit::sheet_frame()).backdrop_color(Color32::from_black_alpha(60)).show(ctx, |ui| {
        kit::mac_spacing(ui);
        ui.set_width(width - 40.0);
        content(ui);
    });
}

// MARK: - Collision prompt (CollisionPromptView.swift:53-123)

fn collision_prompt(ctx: &egui::Context, q: &mut Queue, st: &mut UiState) {
    let Some(prompt) = q.prompt.clone() else { return };
    // Esc = Cancel (`.keyboardShortcut(.cancelAction)`), ↩ = Rename (`.defaultAction`).
    let (esc, ret) = kit::sheet_keys(ctx, true);
    let mut decision: Option<(CollisionDecision, bool)> = None;
    if esc {
        decision = Some((CollisionDecision::Cancel, false));
    } else if ret {
        decision = Some((CollisionDecision::Rename(prompt.suggested_rename.clone()), st.prompt_apply_all));
    }
    let file = crate::naming::last_path_component(&prompt.existing);
    let dir = prompt.existing.parent().map(|d| d.to_string_lossy().into_owned()).unwrap_or_default();
    let rename = crate::naming::last_path_component(&prompt.suggested_rename);
    // `.frame(width: 460)`.
    modal(ctx, "glenc.sheet.collision", 460.0, |ui| {
        ui.spacing_mut().item_spacing.y = 14.0;
        ui.horizontal_top(|ui| {
            ui.spacing_mut().item_spacing.x = 12.0;
            let r = kit::symbol_slot(ui, 44.0, 36.0);
            kit::warning_triangle(ui.painter(), r, look::ORANGE, Color32::from_rgb(40, 40, 40));
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing.y = 4.0;
                let w = ui.available_width();
                kit::text(ui, "Output file already exists", kit::headline(), look::TEXT);
                kit::elided(ui, &file, kit::mono(12.0), look::SECONDARY, w);
                kit::elided(ui, &format!("in {dir}"), kit::caption(), look::SECONDARY, w);
            });
        });
        kit::text(ui, "What should GlEnc do for this job?", kit::system(13.0), look::TEXT);
        let mut job = egui::text::LayoutJob::default();
        let fmt = |bold: bool| egui::TextFormat {
            font_id: if bold { egui::FontId::new(12.0, egui::FontFamily::Name(glance_ui::fonts::SEMIBOLD.into())) } else { kit::system(12.0) },
            color: look::SECONDARY,
            ..Default::default()
        };
        job.append("Rename would write to ", 0.0, fmt(false));
        job.append(&rename, 0.0, fmt(true));
        job.append(".", 0.0, fmt(false));
        job.wrap.max_width = ui.available_width();
        ui.add(egui::Label::new(job).wrap());
        // `.padding(.vertical, 2)`.
        ui.scope(|ui| {
            ui.spacing_mut().item_spacing.y = 0.0;
            ui.add_space(2.0);
            ui.checkbox(&mut st.prompt_apply_all, RichText::new("Apply to all remaining collisions in this batch").font(kit::system(13.0)));
            ui.add_space(2.0);
        });
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 10.0;
            if kit::button(ui, "Overwrite", true).clicked() {
                decision = Some((CollisionDecision::Overwrite, st.prompt_apply_all));
            }
            if kit::button(ui, "Skip", true).clicked() {
                decision = Some((CollisionDecision::Skip, st.prompt_apply_all));
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if kit::default_button(ui, "Rename", true).clicked() {
                    decision = Some((CollisionDecision::Rename(prompt.suggested_rename.clone()), st.prompt_apply_all));
                }
                // Cancel is exempt from "apply to all": it ends the session.
                if kit::button(ui, "Cancel", true).clicked() {
                    decision = Some((CollisionDecision::Cancel, false));
                }
            });
        });
    });
    if let Some((d, all)) = decision {
        q.answer_prompt(d, all);
        // A new prompt is a new sheet: its checkbox starts off (`@State applyToAll = false`).
        st.prompt_apply_all = false;
    }
}

// MARK: - Custom size: the rules (ResizeCustomSheet.swift:31-220)

/// The largest width or height the sheet takes (wider than 16K UHD).
pub const MAX_DIMENSION: i64 = 16384;

/// The sheet's fields when the targets share no preset or custom size.
pub const FALLBACK_SIZE: (u32, u32) = (1920, 1080);

/// `roundedToMultiple(_:of:)`: the nearest multiple of `alignment`, ties up, at least `alignment`; an alignment of
/// 1 (or 0) means any positive size (`max(1, n)`).
pub fn rounded_to_multiple(n: i64, alignment: u32) -> i64 {
    let a = i64::from(alignment.max(1));
    if a == 1 {
        return n.max(1);
    }
    if n <= 0 {
        return a;
    }
    let rounded = (n.saturating_add(a / 2) / a) * a;
    rounded.max(a)
}

/// The note under the title, by the codec's alignment.
pub fn alignment_note(alignment: u32) -> String {
    match alignment {
        0 | 1 => "Any dimensions are accepted — this codec needs no alignment.".into(),
        2 => "Rounded to the nearest even dimension on commit — H.264/HEVC require even (4:2:0) dimensions.".into(),
        a => format!("Rounded to the nearest {a}-pixel multiple on commit."),
    }
}

/// The fields' first values: the size every target shares when it is a preset or a custom size, else 1920×1080
/// (`SettingsBarView.customSheetInitialDims`, `JobCardView.currentCustomWidth`).
pub fn initial_size(sizes: &[OutputSize]) -> (u32, u32) {
    let common = sizes.first().filter(|f| sizes.iter().all(|s| s == *f));
    match common {
        Some(OutputSize::Preset(p)) => p.dimensions(),
        Some(OutputSize::Custom { width, height }) => (*width, *height),
        _ => FALLBACK_SIZE,
    }
}

/// What Save would do (`SavePresetPreview`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SavePreview {
    WillReplace { name: String, width: u32, height: u32 },
    WillCreate { name: String, width: u32, height: u32 },
}

/// The Custom size sheet's fields and what they allow.
#[derive(Clone, Copy, Debug)]
pub struct CustomSizeForm<'a> {
    pub width: &'a str,
    pub height: &'a str,
    pub name: &'a str,
    /// The targets' codec alignment (the largest of them).
    pub alignment: u32,
    pub presets: &'a [NamedSize],
}

impl CustomSizeForm<'_> {
    /// Swift's `Int(String)`: an optional sign and ASCII digits, nothing else.
    fn parse(s: &str) -> Option<i64> {
        s.parse::<i64>().ok()
    }
    pub fn parsed_width(&self) -> Option<i64> {
        Self::parse(self.width)
    }
    pub fn parsed_height(&self) -> Option<i64> {
        Self::parse(self.height)
    }

    /// Both are integers in 1…16384.
    pub fn is_valid(&self) -> bool {
        matches!((self.parsed_width(), self.parsed_height()), (Some(w), Some(h)) if (1..=MAX_DIMENSION).contains(&w) && (1..=MAX_DIMENSION).contains(&h))
    }

    /// The size Commit writes: both rounded to the alignment.
    pub fn rounded(&self) -> Option<(u32, u32)> {
        if !self.is_valid() {
            return None;
        }
        let (w, h) = (self.parsed_width()?, self.parsed_height()?);
        let r = |n: i64| u32::try_from(rounded_to_multiple(n, self.alignment)).ok();
        Some((r(w)?, r(h)?))
    }

    /// "rounded to W×H" while the typed size is not already aligned.
    pub fn rounding_note(&self) -> Option<String> {
        let (rw, rh) = self.rounded()?;
        let (w, h) = (self.parsed_width()?, self.parsed_height()?);
        if i64::from(rw) == w && i64::from(rh) == h {
            return None;
        }
        Some(format!("rounded to {rw}×{rh}"))
    }

    /// The inline error, in Swift's order; none while both fields are empty.
    pub fn validation_message(&self) -> Option<&'static str> {
        if self.width.is_empty() && self.height.is_empty() {
            return None;
        }
        let (Some(w), Some(h)) = (self.parsed_width(), self.parsed_height()) else { return Some("Enter integer dimensions.") };
        if w <= 0 {
            return Some("Width must be positive.");
        }
        if h <= 0 {
            return Some("Height must be positive.");
        }
        if w > MAX_DIMENSION {
            return Some("Width exceeds 16384.");
        }
        if h > MAX_DIMENSION {
            return Some("Height exceeds 16384.");
        }
        None
    }

    pub fn trimmed_name(&self) -> &str {
        self.name.trim()
    }

    /// A saved size already has this name (trimmed, case-insensitive).
    pub fn exists_by_name(&self) -> bool {
        let needle = self.trimmed_name().to_lowercase();
        self.presets.iter().any(|p| p.name.trim().to_lowercase() == needle)
    }

    /// Save: a valid size and a new name.
    pub fn can_save(&self) -> bool {
        self.is_valid() && !self.trimmed_name().is_empty() && !self.exists_by_name()
    }

    /// Update: a valid size and a name already saved.
    pub fn can_update(&self) -> bool {
        self.is_valid() && !self.trimmed_name().is_empty() && self.exists_by_name()
    }

    /// The line under the name field. As Swift's, it is computed only when Save is possible, so the "already exists"
    /// warning never shows (Swift's `savePresetPreview` guards on `canSavePreset`, which excludes a saved name).
    pub fn save_preview(&self) -> Option<SavePreview> {
        if !self.can_save() {
            return None;
        }
        let (width, height) = self.rounded()?;
        let name = self.trimmed_name().to_owned();
        if self.exists_by_name() { Some(SavePreview::WillReplace { name, width, height }) } else { Some(SavePreview::WillCreate { name, width, height }) }
    }

    /// The saved size Save / Update hand to `Settings::add_custom_preset` (a fresh id; Update keeps the old one there).
    pub fn preset(&self) -> Option<NamedSize> {
        let (width, height) = self.rounded()?;
        Some(NamedSize { id: new_preset_id(), name: self.trimmed_name().to_owned(), width, height })
    }
}

/// A new `UUID().uuidString`.
pub fn new_preset_id() -> String {
    uuid::Uuid::new_v4().hyphenated().to_string().to_uppercase()
}

/// Write a size to the rows (`Some`) or the defaults for new files (`None`).
pub fn apply_size(q: &mut Queue, rows: Option<&[JobId]>, size: OutputSize) {
    match rows {
        Some(ids) => {
            let ids = ids.iter().copied().collect();
            q.apply_settings(&ids, &move |s, _| s.output_size = size);
        }
        None => {
            let mut s = q.default_settings();
            s.output_size = size;
            q.set_default_settings(s);
        }
    }
}

/// The targets' sizes and their codec alignment (the largest; 1 with no target).
fn targets(q: &Queue, rows: Option<&[JobId]>) -> (Vec<OutputSize>, u32) {
    let settings: Vec<_> = match rows {
        Some(ids) => ids.iter().filter_map(|id| q.job(*id)).map(|j| j.settings.clone()).collect(),
        None => vec![q.default_settings()],
    };
    let alignment = settings.iter().map(|s| s.codec.dimension_alignment()).max().unwrap_or(1);
    (settings.into_iter().map(|s| s.output_size).collect(), alignment)
}

// MARK: - Custom size: the sheet (ResizeCustomSheet.swift:222-349)

enum CustomAction {
    Cancel,
    Commit { save: bool },
}

fn custom_size(ctx: &egui::Context, q: &mut Queue, st: &mut UiState) {
    let Some(Sheet::CustomSize { rows, width, height, name }) = st.sheet.as_mut() else { return };
    let (sizes, alignment) = targets(q, rows.as_deref());
    let first = !st.sheets.custom_ready;
    if first {
        st.sheets.custom_ready = true;
        if width.is_empty() && height.is_empty() {
            let (w, h) = initial_size(&sizes);
            *width = w.to_string();
            *height = h.to_string();
        }
    }
    let presets = q.settings.values().custom_presets.clone();
    let valid = CustomSizeForm { width, height, name, alignment, presets: &presets }.is_valid();
    let (esc, ret) = kit::sheet_keys(ctx, valid);
    let mut action = if esc {
        Some(CustomAction::Cancel)
    } else if ret {
        Some(CustomAction::Commit { save: false })
    } else {
        None
    };
    let width_id = Id::new("glenc.sheet.custom.width");
    // `.frame(width: 380)`, `.padding(20)`.
    modal(ctx, "glenc.sheet.custom", 380.0, |ui| {
        ui.spacing_mut().item_spacing.y = 14.0;
        ui.horizontal_top(|ui| {
            ui.spacing_mut().item_spacing.x = 12.0;
            let r = kit::symbol_slot(ui, 44.0, 36.0);
            kit::expand_vertical(ui.painter(), r, look::ACCENT);
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing.y = 4.0;
                kit::text(ui, "Custom output size", kit::headline(), look::TEXT);
                kit::text(ui, alignment_note(alignment), kit::system(11.0), look::SECONDARY);
            });
        });
        egui::Grid::new("glenc.sheet.custom.grid").spacing([8.0, 8.0]).show(ui, |ui| {
            for (label, field, hint, id) in [("Width:", &mut *width, "1920", Some(width_id)), ("Height:", &mut *height, "1080", None)] {
                ui.label(RichText::new(label).font(kit::system(13.0)));
                let mut te = egui::TextEdit::singleline(field).hint_text(hint).desired_width(96.0 - 8.0).horizontal_align(Align::RIGHT).font(kit::system(13.0));
                if let Some(id) = id {
                    te = te.id(id);
                }
                let out = te.show(ui);
                if first && id.is_some() {
                    // The sheet opens with the width field focused and its text selected, as AppKit's first key view.
                    out.response.request_focus();
                    let mut state = out.state;
                    state.cursor.set_char_range(Some(egui::text::CCursorRange::select_all(&out.galley)));
                    state.store(ui.ctx(), width_id);
                }
                ui.label(RichText::new("px").font(kit::system(13.0)).color(look::SECONDARY));
                ui.end_row();
            }
        });
        let form = CustomSizeForm { width, height, name, alignment, presets: &presets };
        // Inline feedback: the error, else the rounding, else a blank line so the sheet keeps its height.
        if let Some(msg) = form.validation_message() {
            kit::text(ui, msg, kit::caption(), look::RED);
        } else if let Some(note) = form.rounding_note() {
            kit::text(ui, note, kit::caption(), look::SECONDARY);
        } else {
            kit::text(ui, " ", kit::caption(), look::SECONDARY);
        }
        ui.separator();
        ui.vertical(|ui| {
            ui.spacing_mut().item_spacing.y = 6.0;
            kit::text(ui, "Save as a named preset (optional)", kit::system(11.0), look::SECONDARY);
            ui.horizontal(|ui| {
                let form = CustomSizeForm { width, height, name, alignment, presets: &presets };
                let (can_save, can_update) = (form.can_save(), form.can_update());
                let buttons = 2.0 * 64.0 + 2.0 * ui.spacing().item_spacing.x + 4.0;
                ui.add(egui::TextEdit::singleline(name).hint_text("e.g. Wall A").desired_width(ui.available_width() - buttons).font(kit::system(13.0)));
                if kit::button(ui, "Save", can_save).on_hover_text("Save as a new preset").on_disabled_hover_text("Save as a new preset").clicked() {
                    action = Some(CustomAction::Commit { save: true });
                }
                let help = "Replace the existing preset with this name";
                if kit::button(ui, "Update", can_update).on_hover_text(help).on_disabled_hover_text(help).clicked() {
                    action = Some(CustomAction::Commit { save: true });
                }
            });
            let form = CustomSizeForm { width, height, name, alignment, presets: &presets };
            match form.save_preview() {
                Some(SavePreview::WillReplace { name, width, height }) => {
                    kit::text(ui, format!("⚠ “{name}” already exists. Click Update to replace it with {width}×{height}."), kit::caption(), look::ORANGE);
                }
                Some(SavePreview::WillCreate { name, width, height }) => {
                    kit::text(ui, format!("Will save as “{name}” — {width}×{height}."), kit::caption(), look::SECONDARY);
                }
                None => {
                    kit::text(ui, " ", kit::caption(), look::SECONDARY);
                }
            }
        });
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            ui.spacing_mut().item_spacing.x = 10.0;
            let form = CustomSizeForm { width, height, name, alignment, presets: &presets };
            if kit::default_button(ui, "Commit", form.is_valid()).clicked() {
                action = Some(CustomAction::Commit { save: false });
            }
            if kit::button(ui, "Cancel", true).clicked() {
                action = Some(CustomAction::Cancel);
            }
        });
    });
    let Some(action) = action else { return };
    let form = CustomSizeForm { width, height, name, alignment, presets: &presets };
    match action {
        CustomAction::Cancel => {}
        CustomAction::Commit { save } => {
            let Some((w, h)) = form.rounded() else { return };
            let preset = if save { form.preset() } else { None };
            let rows = rows.clone();
            if let Some(p) = preset {
                q.settings.add_custom_preset(p);
            }
            apply_size(q, rows.as_deref(), OutputSize::Custom { width: w, height: h });
        }
    }
    st.sheet = None;
}

// MARK: - Manage saved sizes (ManageSizesSheet.swift:17-82)

fn manage_sizes(ctx: &egui::Context, settings: &mut Settings, st: &mut UiState) {
    // Done is the default button (↩); Esc dismisses the sheet as SwiftUI's does.
    let (esc, ret) = kit::sheet_keys(ctx, true);
    let mut close = esc || ret;
    let mut remove: Option<String> = None;
    // `.frame(width: 360)`.
    modal(ctx, "glenc.sheet.manage", 360.0, |ui| {
        ui.spacing_mut().item_spacing.y = 14.0;
        ui.horizontal_top(|ui| {
            ui.spacing_mut().item_spacing.x = 12.0;
            let r = kit::symbol_slot(ui, 40.0, 32.0);
            kit::rectangle_stack(ui.painter(), r, look::ACCENT);
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing.y = 4.0;
                kit::text(ui, "Manage saved sizes", kit::headline(), look::TEXT);
                kit::text(
                    ui,
                    "Delete a preset to remove it from the Output Size menu. Re-save a name from the Custom… sheet to replace its dimensions.",
                    kit::system(11.0),
                    look::SECONDARY,
                );
            });
        });
        let presets = &settings.values().custom_presets;
        if presets.is_empty() {
            let (rect, _) = ui.allocate_exact_size(vec2(ui.available_width(), 80.0), egui::Sense::hover());
            ui.painter().text(rect.center(), egui::Align2::CENTER_CENTER, "No saved sizes yet.", kit::system(13.0), look::SECONDARY);
        } else {
            egui::Frame::new().fill(look::LIST).corner_radius(6).stroke(egui::Stroke::new(1.0, look::SECONDARY.gamma_multiply(0.25))).show(ui, |ui| {
                egui::ScrollArea::vertical().max_height(220.0).auto_shrink([false, true]).show(ui, |ui| {
                    ui.spacing_mut().item_spacing.y = 0.0;
                    for p in presets {
                        egui::Frame::new().inner_margin(egui::Margin::symmetric(8, 6)).show(ui, |ui| {
                            ui.horizontal(|ui| {
                                let w = ui.available_width() - 24.0;
                                kit::elided(ui, &p.label(), kit::system(13.0), look::TEXT, w);
                                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                    let (r, resp) = ui.allocate_exact_size(vec2(16.0, 16.0), egui::Sense::click());
                                    let color = if resp.hovered() { look::TEXT } else { look::SECONDARY };
                                    kit::trash(ui.painter(), r.shrink(1.0), color);
                                    if resp.on_hover_text("Delete this saved size").clicked() {
                                        remove = Some(p.id.clone());
                                    }
                                });
                            });
                        });
                        let y = ui.cursor().top();
                        let x = ui.max_rect().x_range();
                        ui.painter().hline(x, y, egui::Stroke::new(1.0, look::SEPARATOR));
                    }
                });
            });
        }
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            if kit::default_button(ui, "Done", true).clicked() {
                close = true;
            }
        });
    });
    if let Some(id) = remove {
        settings.remove_custom_preset(&id);
    }
    if close {
        st.sheet = None;
    }
}
