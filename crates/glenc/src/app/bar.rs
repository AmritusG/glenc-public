//! The settings bar (Swift GlEnc 1.6.2 `SettingsBarView.swift`): every option a row offers, for the defaults for
//! new files (0 or 1 row selected) or for the selected rows (2+), `VStack(spacing: 4)`:
//!
//! - the header (caption): "Defaults for new files — select 2+ clips (⌘-click, ⇧-click, ⌘A) to edit them
//!   together", or the stack icon and "Editing N selected clips (k locked, skipped)" in the accent colour;
//! - codec: family; DXV / HAP alpha; Alpha Type; ProRes variant; H.264 / HEVC container and Advanced; HAP
//!   Chunks — each shown when some target has that codec, "Mixed …" when they differ, "  3/5" when only some
//!   targets take it;
//! - audio: On / Off / Mixed and the rate;
//! - resize: Size (Custom… / Manage Sizes… open the sheets), Quality and Aspect (disabled while every target is
//!   Original).
//!
//! A batch edit goes to the selection through `Queue::apply_from_settings_bar` (locked rows are skipped), else to
//! the defaults.

use super::list::Owner;
use super::list::rows_kit::{self as kit, Edit, SizeChoice};
use super::list::rows_logic::{self as logic, common, partial};
use super::{Sheet, UiState, look};
use crate::job::{EncodeJob, JobSettings, Status};
use crate::queue::Queue;
use egui::{Id, Ui, vec2};
use glance_encode::codec::{OutputContainer, ProResVariant};
use glance_encode::size::OutputSize;
use glance_media::AlphaRule;

pub fn show(ui: &mut Ui, q: &mut Queue, st: &mut UiState) {
    let batch = q.is_batch();
    let selected: Vec<EncodeJob> = q.selected_jobs().into_iter().cloned().collect();
    let targets: Vec<JobSettings> = if batch { selected.iter().map(|j| j.settings.clone()).collect() } else { vec![q.default_settings()] };
    let original = if batch { logic::original_label(&selected.iter().collect::<Vec<_>>()) } else { "Original".to_owned() };
    let alpha_type_targets: Vec<JobSettings> = if batch {
        selected.iter().filter(|j| j.alpha_report.is_some_and(|r| r.rule == AlphaRule::Choosable)).map(|j| j.settings.clone()).collect()
    } else {
        targets.clone()
    };
    let presets = q.settings.values().custom_presets.clone();
    let locked = selected.iter().filter(|j| !matches!(j.status, Status::Queued | Status::Failed)).count();
    let mut out: Option<Edit> = None;
    let mut choice: Option<SizeChoice> = None;
    ui.vertical(|ui| {
        ui.spacing_mut().item_spacing = vec2(16.0, 4.0);
        header(ui, batch, targets.len(), locked);
        let bar = Bar { batch, targets: &targets, alpha_type_targets: &alpha_type_targets, original: &original };
        bar.codec_row(ui, st, &mut out);
        bar.audio_row(ui, &mut out);
        bar.resize_row(ui, &presets, &mut out, &mut choice);
    });
    match choice {
        Some(SizeChoice::Size(size)) => out = Some(kit::edit(move |s, _| s.output_size = size)),
        Some(SizeChoice::Custom) => {
            let (w, h) = logic::custom_sheet_dims(common(&targets, |s| s.output_size));
            let rows = batch.then(|| selected.iter().map(|j| j.id).collect());
            st.sheet = Some(Sheet::CustomSize { rows, width: w.to_string(), height: h.to_string(), name: String::new() });
        }
        Some(SizeChoice::Manage) => st.sheet = Some(Sheet::ManageSizes),
        None => {}
    }
    if let Some(e) = out {
        q.apply_from_settings_bar(&*e);
    }
}

fn header(ui: &mut Ui, batch: bool, count: usize, locked: usize) {
    let caption = kit::font(look::size::CAPTION);
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 6.0;
        ui.set_min_height(13.0);
        if batch {
            let s = logic::batch_header(count, locked);
            let s = logic::truncate_tail(&s, ui.available_width() - 17.0, |t| kit::width_of(ui, t, &caption));
            kit::icon_text(ui, kit::stack_3d, 11.0, 6.0, &s, caption, look::ACCENT);
        } else {
            kit::text(ui, "Defaults for new files", caption.clone(), look::SECONDARY);
            let rest = "— select 2+ clips (⌘-click, ⇧-click, ⌘A) to edit them together";
            let rest = logic::truncate_tail(rest, ui.available_width(), |t| kit::width_of(ui, t, &caption));
            kit::text(ui, rest, caption, super::list::faded(look::SECONDARY, 0.7));
        }
    });
}

/// What the bar shows: the targets' settings.
struct Bar<'a> {
    batch: bool,
    targets: &'a [JobSettings],
    alpha_type_targets: &'a [JobSettings],
    original: &'a str,
}

impl Bar<'_> {
    fn partial(&self, applicable: usize) -> String {
        partial(self.batch, applicable, self.targets.len())
    }

    fn codec_row(&self, ui: &mut Ui, st: &mut UiState, out: &mut Option<Edit>) {
        let t = self.targets;
        let dxv: Vec<JobSettings> = t.iter().filter(|s| s.is_dxv_family()).cloned().collect();
        let prores: Vec<JobSettings> = t.iter().filter(|s| s.is_prores()).cloned().collect();
        let video: Vec<JobSettings> = t.iter().filter(|s| s.is_h264_or_hevc()).cloned().collect();
        let hap: Vec<JobSettings> = t.iter().filter(|s| s.is_hap()).cloned().collect();
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 16.0;
            let family = common(t, kit::family_label).unwrap_or("Mixed codecs");
            let r = kit::menu(ui, family, true, |ui| *out = kit::codec_family_items(ui).or(out.take()));
            kit::help(r, if self.batch { "Codec for the selected clips." } else { "Default codec for newly-dropped files." });
            if !dxv.is_empty() {
                let label = common(&dxv, kit::alpha_label).unwrap_or("Mixed alpha").to_owned() + &self.partial(dxv.len());
                let r = kit::menu(ui, &label, true, |ui| *out = kit::alpha_items(ui).or(out.take()));
                kit::help(r, "Alpha for the DXV/HAP clips.");
            }
            let at = self.alpha_type_targets;
            if !at.is_empty() {
                let label = "Alpha Type: ".to_owned() + common(at, |s| logic::alpha_type_label(s.alpha_type)).unwrap_or("Mixed") + &self.partial(at.len());
                let r = kit::menu(ui, &label, true, |ui| *out = kit::alpha_type_items(ui).or(out.take()));
                kit::help(
                    r,
                    if self.batch {
                        "What the selected DXV sources' colour is (Resolume Arena's \"Alpha Type\"). Premultiplied is un-premultiplied on read."
                    } else {
                        "Alpha Type for newly-dropped DXV sources with alpha (Resolume Arena's default: Premultiplied)."
                    },
                );
            }
            if !prores.is_empty() {
                let variant = |s: &JobSettings| match s.codec {
                    glance_encode::codec::OutputCodec::ProRes(v) => v,
                    _ => ProResVariant::ProRes422,
                };
                let label = common(&prores, |s| variant(s).label()).unwrap_or("Mixed variant").to_owned() + &self.partial(prores.len());
                let r = kit::menu(ui, &label, true, |ui| *out = kit::prores_items(ui).or(out.take()));
                kit::help(r, "ProRes variant for the ProRes clips.");
            }
            if !video.is_empty() {
                let label = common(&video, |s| s.container.label()).unwrap_or("Mixed container").to_owned() + &self.partial(video.len());
                let r = kit::menu(ui, &label, true, |ui| *out = kit::container_items(ui, &[OutputContainer::Mov, OutputContainer::Mp4]).or(out.take()));
                kit::help(r, "Container for the H.264/HEVC clips.");
                let trigger = kit::help(kit::menu_label(ui, &("Advanced".to_owned() + &self.partial(video.len())), true), "Advanced H.264/HEVC options");
                if trigger.clicked() {
                    st.rows.advanced = if st.rows.advanced == Some(Owner::Bar) { None } else { Some(Owner::Bar) };
                }
                let mut open = st.rows.advanced == Some(Owner::Bar);
                let id = Id::new("glenc-bar-advanced");
                let batch = self.batch;
                kit::popover(ui, id, &trigger, &mut open, st.rows.menu_was_open, |ui| {
                    kit::text(ui, "Advanced", kit::semibold(look::size::HEADLINE), look::TEXT);
                    if let Some(rep) = video.first()
                        && let Some(e) = kit::video_advanced(ui, id, rep)
                    {
                        *out = Some(e);
                    }
                    if batch {
                        let differ = common(&video, |s| s.video).is_none();
                        ui.add(
                            egui::Label::new(
                                egui::RichText::new(logic::advanced_batch_note(video.len(), differ))
                                    .font(kit::font(look::size::CAPTION))
                                    .color(look::SECONDARY),
                            )
                            .wrap(),
                        );
                    }
                });
                if !open && st.rows.advanced == Some(Owner::Bar) {
                    st.rows.advanced = None;
                }
            }
            if !hap.is_empty() {
                let c = common(&hap, |s| s.hap_chunks);
                let base = i64::from(c.or_else(|| hap.iter().map(|s| s.hap_chunks).min()).unwrap_or(1));
                ui.horizontal(|ui| {
                    ui.spacing_mut().item_spacing.x = 4.0;
                    let (_, delta) = kit::chunks_stepper(ui, &c.map_or_else(|| "–".to_owned(), |n| n.to_string()), true);
                    if delta != 0 {
                        let n = base + delta;
                        *out = Some(kit::edit(move |s, _| s.set_hap_chunks(n)));
                    }
                    let p = self.partial(hap.len());
                    if !p.is_empty() {
                        kit::text(ui, p, kit::font(look::size::BODY), look::SECONDARY);
                    }
                });
            }
        });
    }

    fn audio_row(&self, ui: &mut Ui, out: &mut Option<Edit>) {
        let t = self.targets;
        let enabled = common(t, |s| s.audio_enabled);
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 16.0;
            let label = match enabled {
                Some(true) => "Audio: On",
                Some(false) => "Audio: Off",
                None => "Audio: Mixed",
            };
            let r = kit::menu(ui, label, true, |ui| *out = kit::audio_enabled_items(ui).or(out.take()));
            kit::help(r, "Clips without an audio track are unaffected.");
            let rate = common(t, |s| s.audio_rate.label()).unwrap_or("Mixed rate");
            kit::menu(ui, rate, enabled != Some(false), |ui| *out = kit::audio_rate_items(ui, t).or(out.take()));
        });
    }

    fn resize_row(&self, ui: &mut Ui, presets: &[crate::json::NamedSize], out: &mut Option<Edit>, choice: &mut Option<SizeChoice>) {
        let t = self.targets;
        let all_original = t.iter().all(|s| s.output_size == OutputSize::Original);
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 16.0;
            let size = common(t, |s| s.output_size).map_or_else(|| "Mixed".to_owned(), |s| logic::size_label(s, self.original));
            kit::menu(ui, &format!("Size: {size}"), true, |ui| *choice = kit::output_size_items(ui, self.original, presets).or(choice.take()));
            let quality = common(t, |s| s.resize_quality.label()).unwrap_or("Mixed");
            let r = kit::menu(ui, &format!("Quality: {quality}"), !all_original, |ui| *out = kit::resize_quality_items(ui).or(out.take()));
            kit::help(r, "Auto picks Lanczos for downscale, Bilinear for upscale. Auto is NOT content-aware — pick Nearest for pixel-art / hard-edge content.");
            let aspect = common(t, |s| s.aspect.label()).unwrap_or("Mixed");
            let r = kit::menu(ui, &format!("Aspect: {aspect}"), !all_original, |ui| *out = kit::aspect_items(ui).or(out.take()));
            kit::help(r, "Fit (letterbox): preserve source aspect, fill remainder with black bars. Distort: stretch to target dims. No effect when source aspect already matches output.");
        });
    }
}
