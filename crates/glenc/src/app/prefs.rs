//! The Preferences window (Swift GlEnc 1.6.2 `PreferencesWindow.swift`, shown by SwiftUI's `Settings` scene, ⌘,):
//! one scrolling pane, 520 pt wide and 620–720 pt tall, with the sections Defaults for New Jobs / Output Location /
//! Output File Collisions / Trim Filename Format / View / Advanced and Reset to Defaults. Every control writes its
//! setting at once (Swift's `didSet`). Swift's pane is its own window; glance-core's shell has one window, so this is
//! an egui window floating over GlEnc's, titled as SwiftUI titles a tab-less Settings window ("GlEnc Settings").

use super::UiState;
use super::look;
use super::sheets::kit;
use crate::queue::Queue;
use crate::settings::{AlphaMode, Change, CheckerboardScope, CollisionPolicy, OutputLocation, QualityTier, TrimFilenameFormat};
use egui::{Align, Color32, CornerRadius, Layout, RichText, Sense, Ui, vec2};
use glance_encode::audio::AudioRate;

/// The window's title.
pub const TITLE: &str = "GlEnc Settings";
/// `.frame(width: 520)`.
pub const WIDTH: f32 = 520.0;
/// `.frame(minHeight: 620, maxHeight: 720)`.
pub const MIN_HEIGHT: f32 = 620.0;
pub const MAX_HEIGHT: f32 = 720.0;

/// This module's own UI state.
#[derive(Debug, Default)]
pub struct PrefsState {
    /// "Experimental: Refined BC4 endpoint search" (Swift's `BC4Config.useRefinement`): session-only, off at every
    /// launch, never persisted. It must reach `HapEncoder::set_refined_bc4` for the HAP encodes started after it is
    /// set (the plumbing from here to the engine belongs to `mod.rs` / `queue.rs` / glance-encode).
    pub refined_bc4: bool,
}

/// The caption under the collision picker (`collisionPolicyDescription`).
pub fn collision_policy_description(p: CollisionPolicy) -> &'static str {
    match p {
        CollisionPolicy::Ask => {
            "Pause the encode and ask each time a job's output filename already exists. The prompt offers Overwrite / Rename / Skip / Cancel and an option to apply the same choice to every remaining collision in the batch."
        }
        CollisionPolicy::Overwrite => {
            "Silently replace the existing file. Fastest workflow but lossy if the existing file matters — pick Auto-rename or Ask if you ever care about prior outputs."
        }
        CollisionPolicy::AutoRename => {
            "Append _2, _3, … before the extension to make a unique filename. Repeated encodes of the same source produce _2, _3, _4 — never overwrites."
        }
    }
}

/// The text after "Folder:" and whether it is the orange fallback note.
pub fn fixed_folder_text(path: &str) -> (&str, bool) {
    if path.is_empty() { ("(none chosen — encode will fall back to same-as-source)", true) } else { (path, false) }
}

/// The "Save to:" menu's items (its own words, not the setting's labels).
pub const OUTPUT_LOCATIONS: [(OutputLocation, &str); 2] = [(OutputLocation::SameAsSource, "Same folder as source"), (OutputLocation::Fixed, "Fixed directory")];
/// The "Brackets:" menu's items.
pub const TRIM_FORMATS: [(TrimFilenameFormat, &str); 2] =
    [(TrimFilenameFormat::Time, "Time  [00.00.83-00.03.33]"), (TrimFilenameFormat::FrameIndices, "Frames  [20-80]")];

pub fn show(ctx: &egui::Context, q: &mut Queue, st: &mut UiState) {
    if !st.prefs_open {
        return;
    }
    let screen = ctx.content_rect();
    // The tallest Swift opens it, within GlEnc's window (Swift's own window may be taller than GlEnc's).
    let height = (screen.height() - 60.0).clamp(160.0, MAX_HEIGHT);
    let mut open = true;
    egui::Window::new(RichText::new(TITLE).font(kit::system(look::size::BODY)))
        .id(egui::Id::new("glenc.prefs"))
        .open(&mut open)
        .collapsible(false)
        .resizable(false)
        .constrain(true)
        .pivot(egui::Align2::CENTER_TOP)
        .default_pos(egui::pos2(screen.center().x, screen.top() + 20.0))
        .fixed_size(vec2(WIDTH, height))
        .frame(egui::Frame::window(&ctx.global_style()).inner_margin(0).fill(look::WINDOW))
        .show(ctx, |ui| {
            egui::ScrollArea::vertical().auto_shrink(false).show(ui, |ui| {
                egui::Frame::new().inner_margin(20).show(ui, |ui| {
                    kit::mac_spacing(ui);
                    ui.set_width(WIDTH - 40.0);
                    body(ui, q, &mut st.prefs);
                });
            });
        });
    st.prefs_open = open;
}

fn body(ui: &mut Ui, q: &mut Queue, prefs: &mut PrefsState) {
    // `VStack(alignment: .leading, spacing: 22)` with a `Divider()` between sections.
    ui.vertical(|ui| defaults_section(ui, q));
    section_divider(ui);
    ui.vertical(|ui| output_section(ui, q));
    section_divider(ui);
    ui.vertical(|ui| collision_section(ui, q));
    section_divider(ui);
    ui.vertical(|ui| format_section(ui, q));
    section_divider(ui);
    ui.vertical(|ui| view_section(ui, q));
    section_divider(ui);
    ui.vertical(|ui| advanced_section(ui, prefs));
    section_divider(ui);
    ui.vertical(|ui| reset_section(ui, q));
}

/// 22 pt, a `Divider()`, 22 pt (less the 8-pt item spacing egui adds around each).
fn section_divider(ui: &mut Ui) {
    ui.add_space(22.0 - 8.0);
    divider(ui);
    ui.add_space(22.0 - 8.0);
}

fn divider(ui: &mut Ui) {
    let (r, _) = ui.allocate_exact_size(vec2(ui.available_width(), 1.0), Sense::hover());
    ui.painter().hline(r.x_range(), r.center().y, egui::Stroke::new(1.0, look::SEPARATOR));
}

fn headline(ui: &mut Ui, s: &str) {
    kit::text(ui, s, kit::headline(), look::TEXT);
}

fn caption(ui: &mut Ui, s: &str) {
    kit::text(ui, s, kit::caption(), look::SECONDARY);
}

fn text_width(ui: &Ui, s: &str, font: &egui::FontId) -> f32 {
    ui.ctx().fonts_mut(|f| f.layout_no_wrap(s.to_owned(), font.clone(), Color32::WHITE).size().x)
}

/// `Picker(label, selection:)` with `.pickerStyle(.menu)` (a pop-up button as wide as its widest item), inside
/// `.frame(maxWidth:)` when given. Returns the newly chosen value.
fn picker<T: Copy + PartialEq>(ui: &mut Ui, id: &str, label: &str, max_width: Option<f32>, value: T, options: &[(T, &str)], enabled: bool) -> Option<T> {
    let mut chosen = None;
    ui.add_enabled_ui(enabled, |ui| {
        ui.horizontal(|ui| {
            let font = kit::system(look::size::BODY);
            let l = ui.label(RichText::new(label).font(font.clone()));
            let widest = options.iter().map(|(_, s)| text_width(ui, s, &font)).fold(0.0, f32::max);
            let mut w = widest + 2.0 * ui.spacing().button_padding.x + ui.spacing().icon_width + 6.0;
            if let Some(m) = max_width {
                w = w.min(m - l.rect.width() - ui.spacing().item_spacing.x);
            }
            let current = options.iter().find(|(v, _)| *v == value).map(|(_, s)| *s).unwrap_or_default();
            egui::ComboBox::from_id_salt(id).width(w).selected_text(RichText::new(current).font(font.clone())).show_ui(ui, |ui| {
                for (v, s) in options {
                    if ui.selectable_label(*v == value, RichText::new(*s).font(font.clone())).clicked() && *v != value {
                        chosen = Some(*v);
                    }
                }
            });
        });
    });
    chosen
}

/// `Picker(label, selection:)` with `.pickerStyle(.segmented)` in `.frame(maxWidth:)`: equal segments filling the
/// width left after the label.
fn segmented<T: Copy + PartialEq>(ui: &mut Ui, label: &str, max_width: f32, value: T, options: &[(T, &str)]) -> Option<T> {
    let mut chosen = None;
    ui.horizontal(|ui| {
        let font = kit::system(look::size::BODY);
        let l = ui.label(RichText::new(label).font(font.clone()));
        let w = (max_width - l.rect.width() - ui.spacing().item_spacing.x).min(ui.available_width());
        let h = 22.0;
        let (rect, _) = ui.allocate_exact_size(vec2(w, h), Sense::hover());
        let p = ui.painter().clone();
        p.rect_filled(rect, CornerRadius::same(6), look::BUTTON.gamma_multiply(0.6));
        let seg = w / options.len() as f32;
        for (i, (v, s)) in options.iter().enumerate() {
            let r = egui::Rect::from_min_size(egui::pos2(rect.left() + seg * i as f32, rect.top()), vec2(seg, h));
            let resp = ui.interact(r, ui.id().with(("glenc.prefs.segment", label, i)), Sense::click());
            let selected = *v == value;
            if selected {
                p.rect_filled(r.shrink(1.5), CornerRadius::same(5), Color32::from_rgb(99, 99, 99));
            } else if resp.hovered() {
                p.rect_filled(r.shrink(1.5), CornerRadius::same(5), Color32::from_rgb(70, 70, 70));
            }
            if i > 0 && !selected && options.get(i - 1).is_none_or(|(pv, _)| *pv != value) {
                p.vline(r.left(), r.y_range().shrink(5.0), egui::Stroke::new(1.0, look::SEPARATOR));
            }
            p.text(r.center(), egui::Align2::CENTER_CENTER, *s, font.clone(), look::TEXT);
            if resp.clicked() && !selected {
                chosen = Some(*v);
            }
        }
    });
    chosen
}

/// `Toggle(label, isOn:)` (a checkbox on macOS).
fn toggle(ui: &mut Ui, label: &str, value: bool) -> Option<bool> {
    let mut v = value;
    ui.checkbox(&mut v, RichText::new(label).font(kit::system(look::size::BODY)));
    (v != value).then_some(v)
}

// MARK: - Sections (PreferencesWindow.swift:51-248)

fn defaults_section(ui: &mut Ui, q: &mut Queue) {
    let v = q.settings.values().clone();
    headline(ui, "Defaults for New Jobs");
    let tiers: Vec<_> = QualityTier::ALL.iter().map(|t| (*t, t.label())).collect();
    if let Some(x) = picker(ui, "glenc.prefs.quality", "Quality:", Some(240.0), v.default_quality, &tiers, true) {
        q.settings.set(Change::DefaultQuality(x));
    }
    let alphas: Vec<_> = AlphaMode::ALL.iter().map(|a| (*a, a.label())).collect();
    if let Some(x) = picker(ui, "glenc.prefs.alpha", "Alpha:", Some(240.0), v.default_alpha, &alphas, true) {
        q.settings.set(Change::DefaultAlpha(x));
    }
    if let Some(x) = toggle(ui, "Carry source audio", v.default_audio_enabled) {
        q.settings.set(Change::DefaultAudioEnabled(x));
    }
    let rates: Vec<_> = AudioRate::ALL.iter().map(|r| (*r, r.label())).collect();
    if let Some(x) = picker(ui, "glenc.prefs.audio_rate", "Audio rate:", Some(240.0), v.default_audio_rate, &rates, v.default_audio_enabled) {
        q.settings.set(Change::DefaultAudioRate(x));
    }
    caption(ui, "Applied to new jobs as they're added to the queue. Existing rows keep their own settings.");
}

fn output_section(ui: &mut Ui, q: &mut Queue) {
    let v = q.settings.values().clone();
    headline(ui, "Output Location");
    if let Some(x) = picker(ui, "glenc.prefs.location", "Save to:", Some(280.0), v.output_location, &OUTPUT_LOCATIONS, true) {
        q.settings.set(Change::OutputLocation(x));
    }
    if v.output_location == OutputLocation::Fixed {
        ui.horizontal(|ui| {
            ui.label(RichText::new("Folder:").font(kit::system(look::size::BODY)));
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if kit::button(ui, "Choose…", true).clicked() {
                    choose_directory(q);
                }
                let (shown, fallback) = fixed_folder_text(&v.fixed_output_path);
                let color = if fallback { look::ORANGE } else { look::TEXT };
                let w = ui.available_width();
                ui.allocate_ui_with_layout(vec2(w, ui.spacing().interact_size.y), Layout::left_to_right(Align::Center), |ui| {
                    kit::elided(ui, shown, kit::system(12.0), color, w);
                });
            });
        });
    }
    caption(ui, "If the chosen folder is missing or unwritable at encode time, GlEnc falls back to the source's folder for that job.");
}

fn collision_section(ui: &mut Ui, q: &mut Queue) {
    let policy = q.settings.values().collision_policy;
    headline(ui, "Output File Collisions");
    let options: Vec<_> = CollisionPolicy::ALL.iter().map(|p| (*p, p.label())).collect();
    if let Some(x) = segmented(ui, "When output file exists:", 360.0, policy, &options) {
        q.settings.set(Change::CollisionPolicy(x));
    }
    caption(ui, collision_policy_description(q.settings.values().collision_policy));
}

fn format_section(ui: &mut Ui, q: &mut Queue) {
    let f = q.settings.values().trim_filename_format;
    headline(ui, "Trim Filename Format");
    if let Some(x) = picker(ui, "glenc.prefs.trim", "Brackets:", Some(320.0), f, &TRIM_FORMATS, true) {
        q.settings.set(Change::TrimFilenameFormat(x));
    }
    caption(ui, "How trim markers render in auto-generated output filenames. Time format reads naturally; frame indices are exact source positions.");
}

fn view_section(ui: &mut Ui, q: &mut Queue) {
    let v = q.settings.values().clone();
    headline(ui, "View");
    if let Some(x) = toggle(ui, "Show preview pane by default", v.preview_pane_visible_by_default) {
        q.settings.set(Change::PreviewPaneVisibleByDefault(x));
    }
    caption(ui, "Applied on app launch. Toggling the pane in-session doesn't change this preference.");
    if let Some(x) = toggle(ui, "Show clip boundary in preview", v.show_clip_boundary) {
        q.settings.set(Change::ShowClipBoundary(x));
    }
    caption(ui, "Outlines the source frame's edge in the preview — useful for clips whose content extends to a black border.");
    let scopes: Vec<_> = CheckerboardScope::ALL.iter().map(|s| (*s, s.label())).collect();
    if let Some(x) = picker(ui, "glenc.prefs.checkerboard", "HAP checkerboard:", None, v.checkerboard_scope, &scopes, true) {
        q.settings.set(Change::CheckerboardScope(x));
    }
    caption(ui, "Transparency checker behind HAP previews. ‘Behind video only’ confines it to the video rect, keeping letterbox bars black.");
}

fn advanced_section(ui: &mut Ui, prefs: &mut PrefsState) {
    headline(ui, "Advanced");
    ui.add_space(4.0);
    if let Some(x) = toggle(ui, "Experimental: Refined BC4 endpoint search", prefs.refined_bc4) {
        prefs.refined_bc4 = x;
    }
    caption(ui, "HAP only (Hap5, HapY, HapA, HapM). DXV is encoded by DXVKit at its best setting. Encode slowdown (about 3×).");
    ui.add_space(2.0);
    kit::text(ui, "Session-only — these toggles reset to their defaults when GlEnc relaunches.", kit::caption(), look::ORANGE);
}

fn reset_section(ui: &mut Ui, q: &mut Queue) {
    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
        // `.controlSize(.small)`.
        ui.spacing_mut().button_padding = vec2(7.0, 1.0);
        let b = egui::Button::new(RichText::new("Reset to Defaults").font(kit::system(look::size::SMALL_CONTROL)));
        if ui.add(b).clicked() {
            // Every value, the checkerboard extent included (fixed on purpose, Amrit 2026-11-14 "fix").
            q.settings.reset_to_defaults();
        }
    });
}

/// `chooseDirectory()`: a folder panel ("Choose Output Folder", can create folders).
fn choose_directory(q: &mut Queue) {
    if let Some(dir) = glance_ui::dialog::pick_folder("Choose Output Folder", None) {
        q.settings.set(Change::FixedOutputPath(dir.to_string_lossy().into_owned()));
    }
}
