//! One queue row (Swift GlEnc 1.6.2 `JobCardView.swift`), `VStack(spacing: 4)` with padding 6 / 10:
//!
//! 1. the source's name (13 pt medium, middle-truncated, the path as its tooltip), the status (80–140 pt: Queued /
//!    progress + % / Done / ⚠ Done · no audio / the error in red) and Cancel / Retry / Show and ×;
//! 2. the codec: family menu; ProRes variant, H.264 / HEVC container or DXV / HAP alpha; "Advanced" (H.264 / HEVC);
//!    "alpha will be flattened"; the Alpha Type (choosable with the hint / stated / hidden); HAP Chunks;
//! 3. audio: "No audio track", or On / Off and the rate (the AAC cap greyed, with its note);
//! 4. Size / Quality / Aspect;
//! 5. Crop: the badge and Edit…, or W / H / X / Y fields with Clear / Cancel / Apply while editing;
//! 6. Trim: "—  (full clip)" or in → out;
//! 7. the output name field with ↻ when edited.
//!
//! Everything but the action buttons is disabled while the row is encoding or done.

use super::list::rows_kit::{self as kit, Edit, SizeChoice};
use super::list::rows_logic::{self as logic, CropField, NameCommit, StatusView};
use super::list::{Owner, RowsState};
use super::{Sheet, UiState, look};
use crate::job::{EncodeJob, JobId, Status};
use crate::queue::Queue;
use egui::{Align, Align2, Id, Key, Layout, Margin, Modifiers, Sense, Shape, Stroke, Ui, pos2, vec2};
use glance_encode::codec::OutputCodec;
use glance_encode::frame::CropRect;
use glance_encode::size::OutputSize;
use glance_media::{AlphaRule, AlphaView};
use std::collections::BTreeSet;
use std::path::PathBuf;

/// What a row asks of the queue, applied after it is drawn.
enum Action {
    Edit(Edit),
    Cancel,
    Retry,
    Reveal(PathBuf),
    Remove,
    BeginCrop,
    ClearCrop,
    CancelCrop,
    ApplyCrop,
    Pending(CropRect),
    SetName(String),
    ResetName,
    Sheet(Sheet),
}

pub fn show(ui: &mut Ui, q: &mut Queue, st: &mut UiState, id: JobId) {
    let Some(job) = q.job(id).cloned() else { return };
    let mut acts: Vec<Action> = Vec::new();
    let editing_crop = q.crop_edit.map(|(j, _)| j);
    let pending = q.crop_edit.and_then(|(_, r)| r);
    let presets = q.settings.values().custom_presets.clone();
    let trim_format = q.settings.values().trim_filename_format;
    egui::Frame::NONE.inner_margin(Margin::symmetric(10, 6)).show(ui, |ui| {
        ui.set_width(ui.available_width());
        ui.spacing_mut().item_spacing = vec2(8.0, 4.0);
        // Rows as tall as Swift's (a 144 pt card measured beside Swift GlEnc; egui's 18 pt default made it 162).
        ui.spacing_mut().interact_size.y = 14.5;
        row_status(ui, &job, &mut acts);
        row_codec(ui, &job, &mut st.rows, &mut acts);
        row_audio(ui, &job, &mut acts);
        row_resize(ui, &job, &presets, &mut acts);
        row_crop(ui, &job, st, editing_crop, pending, &mut acts);
        row_trim(ui, &job, trim_format);
        row_name(ui, &job, st, &mut acts);
    });
    for a in acts {
        match a {
            Action::Edit(e) => q.apply_settings(&BTreeSet::from([id]), &*e),
            Action::Cancel => q.cancel(id),
            Action::Retry => q.retry(id),
            Action::Reveal(p) => reveal(&p),
            Action::Remove => q.remove(id),
            Action::BeginCrop => q.begin_crop_edit(id),
            Action::ClearCrop => q.clear_crop_edit(),
            Action::CancelCrop => q.cancel_crop_edit(),
            Action::ApplyCrop => q.apply_crop_edit(),
            Action::Pending(r) => q.set_pending_crop(Some(r)),
            Action::SetName(n) => q.set_output_name(id, n),
            Action::ResetName => q.reset_output_name(id),
            Action::Sheet(s) => st.sheet = Some(s),
        }
    }
}

fn reveal(path: &std::path::Path) {
    #[cfg(target_os = "macos")]
    if let Err(e) = glance_platform::reveal_in_finder(path) {
        eprintln!("GlEnc: couldn't reveal {}: {e:?}", path.display());
    }
    #[cfg(not(target_os = "macos"))]
    let _ = path;
}

// MARK: - Row 1: name, status, actions

fn row_status(ui: &mut Ui, job: &EncodeJob, acts: &mut Vec<Action>) {
    ui.allocate_ui_with_layout(vec2(ui.available_width(), 16.0), Layout::right_to_left(Align::Center), |ui| {
        ui.spacing_mut().item_spacing.x = 4.0;
        // × (`xmark`, 10 pt medium, borderless).
        let x = kit::icon_button(ui, vec2(16.0, 16.0), job.status != Status::Encoding, |p, c, col| kit::xmark(p, c, 10.0, col));
        if kit::help(x, "Remove from queue").clicked() {
            acts.push(Action::Remove);
        }
        match job.status {
            Status::Queued | Status::Encoding => {
                if kit::small_button(ui, "Cancel", true, false).clicked() {
                    acts.push(Action::Cancel);
                }
            }
            Status::Failed => {
                if kit::small_button(ui, "Retry", true, false).clicked() {
                    acts.push(Action::Retry);
                }
            }
            Status::Done => {
                if kit::small_button(ui, "Show", job.output_path.is_some(), false).clicked()
                    && let Some(p) = &job.output_path
                {
                    acts.push(Action::Reveal(p.clone()));
                }
            }
        }
        ui.add_space(4.0);
        let status_w = (ui.available_width() - 48.0).clamp(80.0, 140.0);
        ui.allocate_ui_with_layout(vec2(status_w, 16.0), Layout::right_to_left(Align::Center), |ui| {
            ui.set_width(status_w);
            status(ui, job, status_w);
        });
        // The source's name, left-aligned in what is left.
        let (rect, resp) = ui.allocate_exact_size(vec2(ui.available_width(), 16.0), Sense::hover());
        let f = kit::medium(13.0);
        let name = job.source.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let shown = logic::truncate_middle(&name, rect.width(), |s| kit::width_of(ui, s, &f));
        ui.painter().text(pos2(rect.left(), rect.center().y), Align2::LEFT_CENTER, shown, f, look::TEXT);
        resp.on_hover_text(job.source.display().to_string());
    });
}

fn status(ui: &mut Ui, job: &EncodeJob, width: f32) {
    let caption = kit::font(look::size::CAPTION);
    let view = StatusView::of(job);
    match &view {
        StatusView::Encoding(p) => {
            ui.spacing_mut().item_spacing.x = 4.0;
            let pct = view.text();
            kit::text(ui, &pct, kit::mono(10.0), look::SECONDARY);
            let w = ui.available_width().max(0.0);
            kit::progress_bar(ui, w, *p);
        }
        StatusView::Queued | StatusView::Done => {
            kit::text(ui, view.text(), caption, look::SECONDARY);
        }
        StatusView::DoneNoAudio(why) => {
            let s = logic::truncate_tail(&view.text(), width - 13.0, |s| kit::width_of(ui, s, &caption));
            let r = kit::icon_text(ui, kit::warning_triangle, 10.0, 3.0, &s, caption, look::ORANGE);
            r.on_hover_text(why);
        }
        StatusView::Failed(e) => {
            let s = logic::truncate_tail(e, width, |s| kit::width_of(ui, s, &caption));
            kit::text(ui, s, caption, look::RED).on_hover_text(e);
        }
    }
}

// MARK: - Row 2: codec

fn row_codec(ui: &mut Ui, job: &EncodeJob, rows: &mut RowsState, acts: &mut Vec<Action>) {
    let s = &job.settings;
    let m = job.is_mutable();
    let mut out: Option<Edit> = None;
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 16.0;
        kit::menu(ui, kit::family_label(s), m, |ui| out = kit::codec_family_items(ui).or(out.take()));
        match s.codec {
            OutputCodec::ProRes(v) => {
                kit::menu(ui, v.label(), m, |ui| out = kit::prores_items(ui).or(out.take()));
            }
            OutputCodec::H264 | OutputCodec::Hevc => {
                kit::menu(ui, s.container.label(), m, |ui| out = kit::container_items(ui, s.codec.allowed_containers()).or(out.take()));
            }
            OutputCodec::Dxv(_) => {
                kit::menu(ui, kit::alpha_label(s), m, |ui| out = kit::alpha_items(ui).or(out.take()));
            }
            OutputCodec::Mjpeg => {}
        }
        if s.codec.has_advanced_settings() {
            let me = Owner::Row(job.id);
            let trigger = kit::help(kit::menu_label(ui, "Advanced", m), "Advanced codec options");
            if trigger.clicked() {
                rows.advanced = if rows.advanced == Some(me) { None } else { Some(me) };
            }
            let mut open = rows.advanced == Some(me) && m;
            let id = Id::new(("glenc-row-advanced", job.id));
            kit::popover(ui, id, &trigger, &mut open, rows.menu_was_open, |ui| {
                kit::text(ui, "Advanced", kit::semibold(look::size::HEADLINE), look::TEXT);
                if let Some(e) = kit::video_advanced(ui, id, s) {
                    out = Some(e);
                }
            });
            if !open && rows.advanced == Some(me) {
                rows.advanced = None;
            }
        }
        if job.alpha_will_be_flattened() {
            let r = kit::icon_text(ui, kit::warning_triangle, 9.0, 3.0, "alpha will be flattened", kit::font(look::size::CAPTION), look::ORANGE);
            kit::help(r, "This ProRes variant has no alpha channel. Choose ProRes 4444 to keep the source's transparency.");
        }
        if let Some(report) = job.alpha_report {
            match report.rule {
                AlphaRule::Opaque => {}
                AlphaRule::Choosable => {
                    let label = format!("Alpha Type: {}", logic::alpha_type_label(s.alpha_type));
                    let r = kit::menu(ui, &label, m, |ui| out = kit::alpha_type_items(ui).or(out.take()));
                    // `HStack(spacing: 6)` of the menu and the hint.
                    ui.spacing_mut().item_spacing.x = 6.0;
                    kit::help(r, "What this DXV source's colour is. A DXV file doesn't say; Resolume Arena calls this \"Alpha Type\" (default Premultiplied). Premultiplied: GlEnc un-premultiplies the colour on read, so every output gets straight colour. Straight: passed through.");
                    if let Some(look_) = report.look {
                        let r = kit::text(ui, look_.label(), kit::font(look::size::CAPTION), look::SECONDARY);
                        r.on_hover_text(format!(
                            "A reading of the first frames (DXV spec 8.5): {} semi-transparent sample pixels, {:.1} % brighter than their alpha. Premultiplied colour can't be brighter than alpha. A hint only: it never changes the setting.",
                            report.samples,
                            report.share() * 100.0
                        ));
                    }
                    ui.spacing_mut().item_spacing.x = 16.0;
                }
                AlphaRule::Stated(view) => {
                    let by = rows.stated_by.entry(job.id).or_insert_with(|| logic::stated_by(glance_media::first_video_fourcc(&job.source))).clone();
                    let t = match view {
                        AlphaView::Premultiplied => "Premultiplied",
                        AlphaView::Straight => "Straight",
                    };
                    let r = kit::text(ui, format!("Alpha Type: {t} ({by})"), kit::font(look::size::BODY), look::SECONDARY);
                    r.on_hover_text(format!("{by} states its alpha, so GlEnc reads it as the file says."));
                }
            }
        }
        if s.is_hap() {
            let (_, delta) = kit::chunks_stepper(ui, &s.hap_chunks.to_string(), m);
            if delta != 0 {
                let n = i64::from(s.hap_chunks) + delta;
                out = Some(kit::edit(move |s, _| s.set_hap_chunks(n)));
            }
        }
    });
    if let Some(e) = out {
        acts.push(Action::Edit(e));
    }
}

// MARK: - Row 3: audio

fn row_audio(ui: &mut Ui, job: &EncodeJob, acts: &mut Vec<Action>) {
    let s = &job.settings;
    let m = job.is_mutable();
    let mut out: Option<Edit> = None;
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 16.0;
        ui.set_min_height(kit::MENU_HEIGHT);
        if job.source_has_audio == Some(false) {
            kit::icon_text(ui, kit::speaker_slash, 9.0, 4.0, "No audio track", kit::font(look::size::CAPTION), look::SECONDARY);
        } else {
            let label = if s.audio_enabled { "Audio: On" } else { "Audio: Off" };
            kit::menu(ui, label, m, |ui| out = kit::audio_enabled_items(ui).or(out.take()));
            let targets = [s.clone()];
            kit::menu(ui, s.audio_rate.label(), m && s.audio_enabled, |ui| out = kit::audio_rate_items(ui, &targets).or(out.take()));
        }
    });
    if let Some(e) = out {
        acts.push(Action::Edit(e));
    }
}

// MARK: - Row 4: size, quality, aspect

fn row_resize(ui: &mut Ui, job: &EncodeJob, presets: &[crate::json::NamedSize], acts: &mut Vec<Action>) {
    let s = &job.settings;
    let m = job.is_mutable();
    let original = s.output_size == OutputSize::Original;
    let original_label = logic::original_label(&[job]);
    let mut out: Option<Edit> = None;
    let mut choice = None;
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 16.0;
        let label = format!("Size: {}", logic::size_label(s.output_size, &original_label));
        kit::menu(ui, &label, m, |ui| choice = kit::output_size_items(ui, &original_label, presets).or(choice.take()));
        let r = kit::menu(ui, &format!("Quality: {}", s.resize_quality.label()), m && !original, |ui| out = kit::resize_quality_items(ui).or(out.take()));
        kit::help(r, "Auto picks Lanczos for downscale, Bilinear for upscale. Auto is NOT content-aware — pick Nearest for pixel-art / hard-edge content.");
        let r = kit::menu(ui, &format!("Aspect: {}", s.aspect.label()), m && !original, |ui| out = kit::aspect_items(ui).or(out.take()));
        kit::help(r, "Fit (letterbox): preserve source aspect, fill remainder with black bars. Distort: stretch to target dims. No effect when source aspect already matches output.");
    });
    match choice {
        Some(SizeChoice::Size(size)) => acts.push(Action::Edit(kit::edit(move |s, _| s.output_size = size))),
        Some(SizeChoice::Custom) => {
            let (w, h) = logic::custom_sheet_dims(Some(s.output_size));
            acts.push(Action::Sheet(Sheet::CustomSize { rows: Some(vec![job.id]), width: w.to_string(), height: h.to_string(), name: String::new() }));
        }
        Some(SizeChoice::Manage) => acts.push(Action::Sheet(Sheet::ManageSizes)),
        None => {}
    }
    if let Some(e) = out {
        acts.push(Action::Edit(e));
    }
}

// MARK: - Row 5: crop

fn row_crop(ui: &mut Ui, job: &EncodeJob, st: &mut UiState, editing: Option<JobId>, pending: Option<CropRect>, acts: &mut Vec<Action>) {
    let this = editing == Some(job.id);
    if this {
        crop_shortcuts(ui, st, acts);
    }
    let mut pending = pending;
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 8.0;
        ui.set_min_height(16.0);
        kit::text(ui, "Crop:", kit::font(look::size::CAPTION), look::SECONDARY);
        if this {
            crop_fields(ui, job, &mut st.rows, &mut pending, acts);
        } else {
            let color = if job.crop.is_some() { look::TEXT } else { look::SECONDARY };
            kit::text(ui, logic::crop_badge(pending, job.crop, false), kit::mono(11.0), color);
        }
        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
            ui.spacing_mut().item_spacing.x = 8.0;
            if this {
                if kit::small_button(ui, "Apply", true, true).clicked() {
                    acts.push(Action::ApplyCrop);
                }
                if kit::small_button(ui, "Cancel", true, false).clicked() {
                    acts.push(Action::CancelCrop);
                }
                if kit::small_button(ui, "Clear", true, false).clicked() {
                    acts.push(Action::ClearCrop);
                }
            } else if kit::small_button(ui, "Edit…", job.is_mutable() && editing.is_none(), false).clicked() {
                acts.push(Action::BeginCrop);
            }
        });
    });
    if !this && st.rows.crop.job == Some(job.id) {
        st.rows.crop = Default::default();
    }
}

/// Escape cancels (`.keyboardShortcut(.cancelAction)`), Return applies (`.defaultAction`) unless a text field has
/// the keyboard (its Return commits the field) or a sheet, prompt or menu is up.
fn crop_shortcuts(ui: &mut Ui, st: &UiState, acts: &mut Vec<Action>) {
    if st.sheet.is_some() || st.rows.menu_was_open || st.rows.advanced.is_some() {
        return;
    }
    let typing = ui.memory(|m| m.focused().is_some());
    ui.input_mut(|i| {
        if i.consume_key(Modifiers::NONE, Key::Escape) {
            acts.push(Action::CancelCrop);
        } else if !typing && i.consume_key(Modifiers::NONE, Key::Enter) {
            acts.push(Action::ApplyCrop);
        }
    });
}

/// The W / H / X / Y fields (`cropFieldsHStack`): each shows the in-flight rectangle (or the source size before
/// one exists) unless it has the keyboard; Return commits it (and keeps it focused), leaving it commits only
/// when its text changed; a corrected value flashes orange.
fn crop_fields(ui: &mut Ui, job: &EncodeJob, rows: &mut RowsState, pending: &mut Option<CropRect>, acts: &mut Vec<Action>) {
    let c = &mut rows.crop;
    let dims = (job.source_width, job.source_height);
    if c.job != Some(job.id) {
        *c = Default::default();
        c.job = Some(job.id);
        c.texts = logic::crop_field_texts(*pending, dims);
        c.last_pending = *pending;
    } else if c.last_pending != *pending {
        sync(c, *pending, dims);
        c.last_pending = *pending;
    }
    let now = ui.input(|i| i.time);
    let ids = CropField::ALL.map(|f| Id::new(("glenc-crop-field", job.id, f.index())));
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 10.0;
        for f in CropField::ALL {
            let i = f.index();
            let bg = ui.painter().add(Shape::Noop);
            let group = ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = 3.0;
                ui.add_space(2.0);
                let (r, _) = ui.allocate_exact_size(vec2(18.0, 16.0), Sense::hover());
                ui.painter().text(pos2(r.right(), r.center().y), Align2::RIGHT_CENTER, f.label(), kit::mono(11.0), look::SECONDARY);
                let resp = ui.add(
                    egui::TextEdit::singleline(&mut c.texts[i])
                        .id(ids[i])
                        .font(kit::mono(11.0))
                        .text_color(look::TEXT)
                        .horizontal_align(Align::RIGHT)
                        .desired_width(f.width() - 8.0)
                        .margin(Margin::symmetric(4, 1))
                        .frame(egui::Frame::new().fill(kit::FIELD).stroke(Stroke::new(1.0, kit::FIELD_BORDER)).corner_radius(3)),
                );
                ui.add_space(2.0);
                if resp.lost_focus() && ui.input(|inp| inp.key_pressed(Key::Enter)) {
                    commit(c, f, job, pending, now, acts);
                    resp.request_focus();
                }
            });
            let a = logic::flash_alpha(now - c.flash[i]);
            if a > 0.0 {
                ui.painter().set(bg, Shape::rect_filled(group.response.rect.expand2(vec2(0.0, 1.0)), 5.0, look::ORANGE.gamma_multiply(a)));
            }
        }
    });
    let focus = ui.memory(|m| CropField::ALL.into_iter().find(|f| m.has_focus(ids[f.index()])));
    let c = &mut rows.crop;
    if focus != c.focus {
        if let Some(old) = c.focus
            && c.texts[old.index()] != c.baseline
        {
            commit(c, old, job, pending, now, acts);
        }
        if let Some(new) = focus {
            c.baseline = c.texts[new.index()].clone();
        }
        c.focus = focus;
    }
}

/// `syncCropFieldStringsFromPending`: every field but the focused one.
fn sync(c: &mut super::list::CropFields, pending: Option<CropRect>, dims: (Option<u32>, Option<u32>)) {
    let texts = logic::crop_field_texts(pending, dims);
    for f in CropField::ALL {
        if c.focus != Some(f) {
            c.texts[f.index()] = texts[f.index()].clone();
        }
    }
}

/// `commitCropField`: parse, refuse without the source size, seed the full frame when nothing is in flight,
/// correct, and show the corrected value in the field.
fn commit(c: &mut super::list::CropFields, f: CropField, job: &EncodeJob, pending: &mut Option<CropRect>, now: f64, acts: &mut Vec<Action>) {
    let dims = (job.source_width, job.source_height);
    let (Some(typed), Some(sw), Some(sh)) = (logic::parse_int(&c.texts[f.index()]), dims.0, dims.1) else {
        sync(c, *pending, dims);
        return;
    };
    let align = i64::from(job.settings.codec.dimension_alignment());
    let (sw, sh) = (i64::from(sw), i64::from(sh));
    let base = pending.unwrap_or_else(|| logic::full_frame_seed(sw, sh, align));
    let r = logic::commit_crop_field(f, typed, base, sw, sh, align);
    *pending = Some(r.rect);
    acts.push(Action::Pending(r.rect));
    c.texts[f.index()] = r.corrected.to_string();
    c.baseline = c.texts[f.index()].clone();
    if r.was_corrected {
        c.flash[f.index()] = now;
    }
}

// MARK: - Row 6: trim

fn row_trim(ui: &mut Ui, job: &EncodeJob, format: crate::settings::TrimFilenameFormat) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 6.0;
        ui.set_min_height(14.0);
        kit::text(ui, "Trim:", kit::font(look::size::CAPTION), look::SECONDARY);
        let color = if job.is_trimmed() { look::TEXT } else { look::SECONDARY };
        kit::text(ui, logic::trim_display(job, format), kit::mono(11.0), color);
    });
}

// MARK: - Row 7: output name (`OutputNameCell`)

fn row_name(ui: &mut Ui, job: &EncodeJob, st: &mut UiState, acts: &mut Vec<Action>) {
    let m = job.is_mutable();
    let id = Id::new(("glenc-name-field", job.id));
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = 4.0;
        let editing = st.editing_name.as_ref().filter(|(e, _)| *e == job.id).map(|(_, t)| t.clone());
        let mut s = editing.clone().unwrap_or_else(|| job.output_name.clone());
        let reset_w = if job.output_name_overridden { 20.0 } else { 0.0 };
        let field = egui::TextEdit::singleline(&mut s)
            .id(id)
            .font(kit::font(look::size::BODY))
            .text_color(if m { look::TEXT } else { kit::DISABLED })
            .frame(egui::Frame::NONE)
            .margin(Margin::ZERO)
            .desired_width((ui.available_width() - reset_w).max(20.0));
        let resp = kit::help(ui.add_enabled(m, field), &job.output_name);
        if resp.has_focus() {
            st.editing_name = Some((job.id, s.clone()));
        }
        if resp.lost_focus() {
            if let NameCommit::Set(n) = logic::name_commit(&s, &job.output_name) {
                acts.push(Action::SetName(n));
            }
            st.editing_name = None;
        }
        if job.output_name_overridden {
            let r = kit::icon_button(ui, vec2(16.0, 16.0), m, |p, c, _| kit::reset_circle(p, c, 12.0, if m { look::SECONDARY } else { kit::DISABLED }));
            if kit::help(r, "Reset to auto-generated name").clicked() {
                if st.editing_name.as_ref().is_some_and(|(e, _)| *e == job.id) {
                    st.editing_name = None;
                }
                acts.push(Action::ResetName);
            }
        }
    });
}
