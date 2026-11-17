//! The pure logic behind the queue column, the rows and the settings bar (Swift GlEnc 1.6.2): the labels
//! (`SettingsControls.swift` `OutputSizeMenuItems.label` / `originalLabel(for:)`, `SettingsBarView.swift` `common` /
//! `partial`), a row's status text (`JobCardView.swift:146-193`), the crop badge and the crop fields' commit
//! (`JobCardView.swift:844-999`, `CropFieldCommit.swift`, `CropDragMath.fullFrameSeedRect`), the trim text
//! (`JobCardView.swift:1016-1045`), the name field's commit (`OutputNameCell.swift:80-90`) and the list's
//! click selection (SwiftUI `List(selection:)`: plain click, ⌘-click, ⇧-click).

use crate::job::{EncodeJob, JobId, JobSettings, Status};
use crate::settings::TrimFilenameFormat;
use glance_encode::codec::H264Profile;
use glance_encode::frame::CropRect;
use glance_encode::size::OutputSize;
use glance_encode::source::AlphaType;
use std::collections::BTreeSet;

// MARK: - Labels

/// The value every element of `list` shares, or `None` when mixed (or empty) (`SettingsBarView.common`).
pub fn common<T: PartialEq>(list: &[JobSettings], f: impl Fn(&JobSettings) -> T) -> Option<T> {
    let first = f(list.first()?);
    list.iter().all(|s| f(s) == first).then_some(first)
}

/// "  3/5" when a setting applies to only some of a batch (`SettingsBarView.partial`), else "".
pub fn partial(is_batch: bool, applicable: usize, total: usize) -> String {
    if is_batch && applicable < total { format!("  {applicable}/{total}") } else { String::new() }
}

/// "Original (1920×1080)" with the size `.original` encodes at (the crop when cropped, else the probed source);
/// "Original (mixed)" when the jobs differ; plain "Original" with no job or none probed yet
/// (`OutputSizeMenuItems.originalLabel(for:)`).
pub fn original_label(jobs: &[&EncodeJob]) -> String {
    let sizes: Vec<(u32, u32)> = jobs.iter().filter_map(|j| j.effective_source_size()).collect();
    let Some(first) = sizes.first() else { return "Original".into() };
    if sizes.iter().any(|s| s != first) {
        return "Original (mixed)".into();
    }
    format!("Original ({}×{})", first.0, first.1)
}

/// The Size menu's collapsed label (`OutputSizeMenuItems.label`): the Original label, "1920×1080" for a preset,
/// "Custom 1500×844".
pub fn size_label(size: OutputSize, original: &str) -> String {
    match size {
        OutputSize::Original => original.to_owned(),
        OutputSize::Preset(p) => {
            let (w, h) = p.dimensions();
            format!("{w}×{h}")
        }
        OutputSize::Custom { width, height } => format!("Custom {width}×{height}"),
    }
}

/// The Custom… sheet's starting size (`JobCardView.currentCustomWidth/Height`, `SettingsBarView.customSheetInitialDims`):
/// the preset's or custom size, else 1920×1080.
pub fn custom_sheet_dims(size: Option<OutputSize>) -> (u32, u32) {
    match size {
        Some(OutputSize::Preset(p)) => p.dimensions(),
        Some(OutputSize::Custom { width, height }) => (width, height),
        _ => (1920, 1080),
    }
}

/// `AlphaType.label`.
pub fn alpha_type_label(t: AlphaType) -> &'static str {
    match t {
        AlphaType::Premultiplied => "Premultiplied",
        AlphaType::Straight => "Straight",
    }
}

/// `VideoEncodeSettings.H264Profile.label`.
pub fn h264_profile_label(p: H264Profile) -> &'static str {
    match p {
        H264Profile::Baseline => "Baseline",
        H264Profile::Main => "Main",
        H264Profile::High => "High",
    }
}

/// The H.264 profiles in Swift's `allCases` order.
pub const H264_PROFILES: [H264Profile; 3] = [H264Profile::Baseline, H264Profile::Main, H264Profile::High];

/// Who states an alpha the format fixes (`AlphaTypeProbe.probe`: "HAP", "ProRes 4444", "ProRes 4444 XQ", "HEVC",
/// else the FourCC), from the first video track's FourCC.
pub fn stated_by(fourcc: Option<[u8; 4]>) -> String {
    let Some(cc) = fourcc else { return String::new() };
    match &cc {
        b"Hap1" | b"Hap5" | b"HapY" | b"HapM" | b"HapA" | b"Hap7" | b"HapH" => "HAP".into(),
        b"ap4h" => "ProRes 4444".into(),
        b"ap4x" => "ProRes 4444 XQ".into(),
        b"hvc1" | b"hev1" => "HEVC".into(),
        _ => String::from_utf8_lossy(&cc).into_owned(),
    }
}

/// "3 jobs" / "1 job" (`ContentView.queueHeader`).
pub fn jobs_label(n: usize) -> String {
    format!("{n} job{}", if n == 1 { "" } else { "s" })
}

/// "42%" (`String(format: "%.0f%%", p * 100)`).
pub fn percent(p: f64) -> String {
    format!("{:.0}%", p * 100.0)
}

/// The settings bar's batch header: "Editing 3 selected clips (1 locked, skipped)".
pub fn batch_header(count: usize, locked: usize) -> String {
    let mut s = format!("Editing {count} selected clips");
    if locked > 0 {
        s.push_str(&format!(" ({locked} locked, skipped)"));
    }
    s
}

/// The note under the bar's Advanced popover in a batch (`SettingsBarView.advancedPopover`).
pub fn advanced_batch_note(count: usize, values_differ: bool) -> String {
    format!(
        "Changes apply to the {count} H.264/HEVC clip{} in the selection{}",
        if count == 1 { "" } else { "s" },
        if values_differ { " (values differ — showing the first)." } else { "." }
    )
}

// MARK: - Status

/// What a row's status area shows (`JobCardView.statusOrProgress`).
#[derive(Clone, Debug, PartialEq)]
pub enum StatusView {
    /// A progress bar and "42%".
    Encoding(f64),
    /// "Queued", secondary.
    Queued,
    /// "Done", secondary.
    Done,
    /// "Done · no audio" with a warning triangle, orange; the reason as the tooltip.
    DoneNoAudio(String),
    /// The error (or "Failed"), red, with itself as the tooltip.
    Failed(String),
}

impl StatusView {
    pub fn of(job: &EncodeJob) -> StatusView {
        match job.status {
            Status::Encoding => StatusView::Encoding(job.progress),
            Status::Queued => StatusView::Queued,
            Status::Done => match &job.audio_warning {
                Some(w) => StatusView::DoneNoAudio(w.clone()),
                None => StatusView::Done,
            },
            Status::Failed => StatusView::Failed(job.error.clone().unwrap_or_else(|| "Failed".into())),
        }
    }

    /// The words shown.
    pub fn text(&self) -> String {
        match self {
            StatusView::Encoding(p) => percent(*p),
            StatusView::Queued => "Queued".into(),
            StatusView::Done => "Done".into(),
            StatusView::DoneNoAudio(_) => "Done · no audio".into(),
            StatusView::Failed(e) => e.clone(),
        }
    }
}

// MARK: - Trim

/// The trim row's text (`JobCardView.trimDisplay`).
pub fn trim_display(job: &EncodeJob, format: TrimFilenameFormat) -> String {
    if !job.is_trimmed() {
        return "—  (full clip)".into();
    }
    let fps = job.source_fps.unwrap_or(0.0);
    match format {
        TrimFilenameFormat::Time => {
            let i = job.in_frame.map_or_else(|| "start".to_owned(), |f| format_time(f, fps));
            let o = job.out_frame.map_or_else(|| "end".to_owned(), |f| format_time(f, fps));
            format!("{i} → {o}")
        }
        TrimFilenameFormat::FrameIndices => {
            let i = job.in_frame.map_or_else(|| "0".to_owned(), |f| f.to_string());
            let o = job.out_frame.map_or_else(|| "end".to_owned(), |f| f.to_string());
            format!("frame {i} → {o}")
        }
    }
}

/// "MM:SS.CC" (`JobCardView.formatTime`); "?" without a frame rate.
pub fn format_time(frame: i64, fps: f64) -> String {
    if fps <= 0.0 {
        return "?".into();
    }
    let total = (frame as f64 / fps).max(0.0);
    let minutes = (total as i64) / 60;
    let seconds_part = total - (minutes * 60) as f64;
    let seconds = seconds_part as i64;
    let centis = ((seconds_part - seconds as f64) * 100.0) as i64;
    format!("{minutes:02}:{seconds:02}.{centis:02}")
}

// MARK: - Crop

/// The crop badge (`JobCardView.formatCropBadge`).
pub fn crop_badge(pending: Option<CropRect>, committed: Option<CropRect>, editing: bool) -> String {
    if editing {
        match pending {
            Some(r) => format!("{}x{} @ ({}, {})", r.width, r.height, r.x, r.y),
            None => "—  (no crop yet)".into(),
        }
    } else {
        match committed {
            Some(r) => format!("{}x{}", r.width, r.height),
            None => "—  (no crop)".into(),
        }
    }
}

/// One of the four crop fields (`CropField`), in tab order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CropField {
    Width,
    Height,
    X,
    Y,
}

impl CropField {
    pub const ALL: [CropField; 4] = [CropField::Width, CropField::Height, CropField::X, CropField::Y];
    pub fn index(self) -> usize {
        match self {
            CropField::Width => 0,
            CropField::Height => 1,
            CropField::X => 2,
            CropField::Y => 3,
        }
    }
    /// The visible label.
    pub fn label(self) -> &'static str {
        match self {
            CropField::Width => "W:",
            CropField::Height => "H:",
            CropField::X => "X:",
            CropField::Y => "Y:",
        }
    }
    /// The field's width (50 for W / H, 40 for X / Y).
    pub fn width(self) -> f32 {
        match self {
            CropField::Width | CropField::Height => 50.0,
            CropField::X | CropField::Y => 40.0,
        }
    }
}

/// The four fields' texts from the in-flight rectangle; with none yet, the source size at (0, 0)
/// (`JobCardView.syncCropFieldStringsFromPending`).
pub fn crop_field_texts(pending: Option<CropRect>, source: (Option<u32>, Option<u32>)) -> [String; 4] {
    match pending {
        Some(r) => [r.width.to_string(), r.height.to_string(), r.x.to_string(), r.y.to_string()],
        None => [source.0.unwrap_or(0).to_string(), source.1.unwrap_or(0).to_string(), "0".into(), "0".into()],
    }
}

/// A field's commit (`CropFieldCommitResult`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CropCommit {
    pub rect: CropRect,
    pub corrected: i64,
    pub was_corrected: bool,
}

/// `CropDragMath.fullFrameSeedRect`: the whole source, floored to the alignment.
pub fn full_frame_seed(source_width: i64, source_height: i64, alignment: i64) -> CropRect {
    let a = alignment.max(1);
    let floor = |d: i64| u32::try_from((d / a * a).max(0)).unwrap_or(u32::MAX);
    CropRect { x: 0, y: 0, width: floor(source_width), height: floor(source_height) }
}

/// Round to the nearest multiple of the alignment, at least the alignment (W / H).
fn round_dim(n: i64, a: i64) -> i64 {
    let a = a.max(1);
    if a == 1 {
        return n.max(1);
    }
    if n <= 0 {
        return a;
    }
    (((n + a / 2) / a) * a).max(a)
}

/// Round to the nearest multiple of the alignment, at least 0 (X / Y).
fn round_pos(n: i64, a: i64) -> i64 {
    let a = a.max(1);
    if a == 1 {
        return n.max(0);
    }
    if n <= 0 {
        return 0;
    }
    ((n + a / 2) / a) * a
}

/// Put a typed value on one component of the in-flight rectangle: minimum, round to the alignment, keep inside the
/// source (`commitCropFieldValue`); the other three components are untouched.
pub fn commit_crop_field(field: CropField, typed: i64, current: CropRect, source_width: i64, source_height: i64, alignment: i64) -> CropCommit {
    let a = alignment.max(1);
    let (cx, cy, cw, ch) = (i64::from(current.x), i64::from(current.y), i64::from(current.width), i64::from(current.height));
    let u = |v: i64| u32::try_from(v.max(0)).unwrap_or(u32::MAX);
    let (corrected, rect) = match field {
        CropField::Width => {
            let max = a.max((source_width - cx) / a * a);
            let v = round_dim(typed, a).min(max);
            (v, CropRect { width: u(v), ..current })
        }
        CropField::Height => {
            let max = a.max((source_height - cy) / a * a);
            let v = round_dim(typed, a).min(max);
            (v, CropRect { height: u(v), ..current })
        }
        CropField::X => {
            let max = ((source_width - cw) / a * a).max(0);
            let v = round_pos(typed, a).min(max);
            (v, CropRect { x: u(v), ..current })
        }
        CropField::Y => {
            let max = ((source_height - ch) / a * a).max(0);
            let v = round_pos(typed, a).min(max);
            (v, CropRect { y: u(v), ..current })
        }
    };
    CropCommit { rect, corrected, was_corrected: corrected != typed }
}

/// Swift's `Int(text)`: an optional sign and digits, nothing else.
pub fn parse_int(text: &str) -> Option<i64> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}

/// The orange flash behind a corrected crop field: in over 0.6 s, out over 0.6 s, at most 60 % (`triggerFlash`).
pub fn flash_alpha(elapsed: f64) -> f32 {
    let ease = |t: f64| {
        let t = t.clamp(0.0, 1.0);
        t * t * (3.0 - 2.0 * t)
    };
    let a = if !(0.0..1.2).contains(&elapsed) {
        0.0
    } else if elapsed < 0.6 {
        ease(elapsed / 0.6)
    } else {
        1.0 - ease((elapsed - 0.6) / 0.6)
    };
    (a * 0.6) as f32
}

// MARK: - Output name

/// What committing the name field does (`OutputNameCell.commitIfChanged`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NameCommit {
    /// Empty or blank: back to the current name.
    Revert,
    /// The same name: nothing.
    Unchanged,
    /// A new name (trimmed): it sticks until ↻.
    Set(String),
}

pub fn name_commit(typed: &str, current: &str) -> NameCommit {
    let t = typed.trim();
    if t.is_empty() {
        NameCommit::Revert
    } else if t == current {
        NameCommit::Unchanged
    } else {
        NameCommit::Set(t.to_owned())
    }
}

// MARK: - Text fitting

/// `.truncationMode(.middle)`: the head and tail of `text` around "…" so it fits `max` by `measure`.
pub fn truncate_middle(text: &str, max: f32, measure: impl Fn(&str) -> f32) -> String {
    if measure(text) <= max {
        return text.to_owned();
    }
    let chars: Vec<char> = text.chars().collect();
    let build = |keep: usize| {
        let head = keep.div_ceil(2);
        let tail = keep / 2;
        let mut s: String = chars[..head].iter().collect();
        s.push('…');
        s.extend(&chars[chars.len() - tail..]);
        s
    };
    let (mut lo, mut hi) = (0usize, chars.len().saturating_sub(1));
    while lo < hi {
        let mid = (lo + hi).div_ceil(2);
        if measure(&build(mid)) <= max { lo = mid } else { hi = mid - 1 }
    }
    build(lo)
}

/// `.truncationMode(.tail)`.
pub fn truncate_tail(text: &str, max: f32, measure: impl Fn(&str) -> f32) -> String {
    if measure(text) <= max {
        return text.to_owned();
    }
    let chars: Vec<char> = text.chars().collect();
    let build = |keep: usize| {
        let mut s: String = chars[..keep].iter().collect();
        s.push('…');
        s
    };
    let (mut lo, mut hi) = (0usize, chars.len().saturating_sub(1));
    while lo < hi {
        let mid = (lo + hi).div_ceil(2);
        if measure(&build(mid)) <= max { lo = mid } else { hi = mid - 1 }
    }
    build(lo)
}

// MARK: - Selection

/// A click on a row of the list (`List(selection:)` on macOS): plain selects that row; ⌘ toggles it; ⇧ selects
/// the rows from the anchor to it. Returns the new selection and anchor.
pub fn click_selection(
    order: &[JobId],
    current: &BTreeSet<JobId>,
    anchor: Option<JobId>,
    clicked: JobId,
    command: bool,
    shift: bool,
) -> (BTreeSet<JobId>, Option<JobId>) {
    let pos = |id: JobId| order.iter().position(|&j| j == id);
    if shift && let (Some(a), Some(c)) = (anchor.and_then(pos), pos(clicked)) {
        let (lo, hi) = (a.min(c), a.max(c));
        let mut set: BTreeSet<JobId> = order[lo..=hi].iter().copied().collect();
        if command {
            set.extend(current.iter().copied());
        }
        return (set, anchor);
    }
    if command {
        let mut set = current.clone();
        if !set.remove(&clicked) {
            set.insert(clicked);
        }
        return (set, Some(clicked));
    }
    (BTreeSet::from([clicked]), Some(clicked))
}

/// The rows a right-click acts on (`.contextMenu(forSelectionType:)`): the selection when the clicked row is in
/// it, else the clicked row.
pub fn context_targets(selected: &BTreeSet<JobId>, clicked: JobId) -> BTreeSet<JobId> {
    if selected.contains(&clicked) { selected.clone() } else { BTreeSet::from([clicked]) }
}

/// "Reset for Re-run" is enabled when not encoding and a target row is finished.
pub fn reset_enabled(jobs: &[EncodeJob], ids: &BTreeSet<JobId>, encoding: bool) -> bool {
    !encoding && jobs.iter().any(|j| ids.contains(&j.id) && j.is_finished())
}

// MARK: - Numbers

/// SwiftUI's `.number` format for a field: no trailing zeros, grouping by thousands ("1,000", "10.5").
pub fn format_number(v: f64) -> String {
    if !v.is_finite() {
        return String::new();
    }
    let s = format!("{}", (v * 1e6).round() / 1e6);
    let (int, frac) = s.split_once('.').map_or((s.as_str(), None), |(i, f)| (i, Some(f)));
    let (sign, digits) = int.strip_prefix('-').map_or(("", int), |d| ("-", d));
    let mut grouped = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(c);
    }
    match frac {
        Some(f) => format!("{sign}{grouped}.{f}"),
        None => format!("{sign}{grouped}"),
    }
}

/// Parse a `.number` field (grouping commas allowed); `None` reverts the field.
pub fn parse_number(text: &str) -> Option<f64> {
    let t: String = text.trim().chars().filter(|c| *c != ',').collect();
    t.parse::<f64>().ok().filter(|v| v.is_finite())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::job::EncodeJob;
    use glance_encode::size::StandardResolution;
    use std::path::PathBuf;

    fn job(id: JobId) -> EncodeJob {
        EncodeJob::new(id, PathBuf::from(format!("/m/clip{id}.mov")), JobSettings::default())
    }

    #[test]
    fn original_labels() {
        let mut a = job(1);
        let mut b = job(2);
        assert_eq!(original_label(&[]), "Original");
        assert_eq!(original_label(&[&a]), "Original");
        a.source_width = Some(1920);
        a.source_height = Some(1080);
        assert_eq!(original_label(&[&a]), "Original (1920×1080)");
        b.source_width = Some(1920);
        b.source_height = Some(1080);
        assert_eq!(original_label(&[&a, &b]), "Original (1920×1080)");
        b.crop = Some(CropRect { x: 0, y: 0, width: 1280, height: 720 });
        assert_eq!(original_label(&[&a, &b]), "Original (mixed)");
        // An unprobed job does not count.
        let c = job(3);
        assert_eq!(original_label(&[&a, &c]), "Original (1920×1080)");
    }

    #[test]
    fn size_labels_and_sheet_dims() {
        assert_eq!(size_label(OutputSize::Original, "Original (mixed)"), "Original (mixed)");
        assert_eq!(size_label(OutputSize::Preset(StandardResolution::Fhd1920x1080), "Original"), "1920×1080");
        assert_eq!(size_label(OutputSize::Custom { width: 1500, height: 844 }, "Original"), "Custom 1500×844");
        assert_eq!(custom_sheet_dims(None), (1920, 1080));
        assert_eq!(custom_sheet_dims(Some(OutputSize::Original)), (1920, 1080));
        assert_eq!(custom_sheet_dims(Some(OutputSize::Preset(StandardResolution::Sq2048))), (2048, 2048));
        assert_eq!(custom_sheet_dims(Some(OutputSize::Custom { width: 7, height: 9 })), (7, 9));
    }

    #[test]
    fn mixed_detection_and_partial() {
        let a = JobSettings::default();
        let mut b = JobSettings::default();
        assert_eq!(common(&[a.clone(), b.clone()], |s| s.audio_enabled), Some(true));
        b.audio_enabled = false;
        assert_eq!(common(&[a.clone(), b.clone()], |s| s.audio_enabled), None);
        assert_eq!(common(&[], |s| s.audio_enabled), None);
        assert_eq!(common(&[b], |s| s.audio_enabled), Some(false));
        assert_eq!(partial(true, 3, 5), "  3/5");
        assert_eq!(partial(true, 5, 5), "");
        assert_eq!(partial(false, 0, 1), "");
        assert_eq!(batch_header(3, 0), "Editing 3 selected clips");
        assert_eq!(batch_header(3, 1), "Editing 3 selected clips (1 locked, skipped)");
        assert_eq!(advanced_batch_note(1, false), "Changes apply to the 1 H.264/HEVC clip in the selection.");
        assert_eq!(advanced_batch_note(2, true), "Changes apply to the 2 H.264/HEVC clips in the selection (values differ — showing the first).");
        assert_eq!(jobs_label(1), "1 job");
        assert_eq!(jobs_label(0), "0 jobs");
    }

    #[test]
    fn status_texts() {
        let mut j = job(1);
        assert_eq!(StatusView::of(&j), StatusView::Queued);
        assert_eq!(StatusView::of(&j).text(), "Queued");
        j.status = Status::Encoding;
        j.progress = 0.426;
        assert_eq!(StatusView::of(&j).text(), "43%");
        j.status = Status::Done;
        assert_eq!(StatusView::of(&j).text(), "Done");
        j.audio_warning = Some("Audio unavailable: x".into());
        assert_eq!(StatusView::of(&j), StatusView::DoneNoAudio("Audio unavailable: x".into()));
        assert_eq!(StatusView::of(&j).text(), "Done · no audio");
        j.status = Status::Failed;
        assert_eq!(StatusView::of(&j).text(), "Failed");
        j.error = Some("Cancelled".into());
        assert_eq!(StatusView::of(&j).text(), "Cancelled");
    }

    #[test]
    fn trim_texts() {
        let mut j = job(1);
        assert_eq!(trim_display(&j, TrimFilenameFormat::Time), "—  (full clip)");
        j.in_frame = Some(30);
        j.source_fps = Some(30.0);
        assert_eq!(trim_display(&j, TrimFilenameFormat::Time), "00:01.00 → end");
        assert_eq!(trim_display(&j, TrimFilenameFormat::FrameIndices), "frame 30 → end");
        j.in_frame = None;
        j.out_frame = Some(3601);
        assert_eq!(trim_display(&j, TrimFilenameFormat::Time), "start → 02:00.03");
        assert_eq!(trim_display(&j, TrimFilenameFormat::FrameIndices), "frame 0 → 3601");
        j.source_fps = None;
        assert_eq!(trim_display(&j, TrimFilenameFormat::Time), "start → ?");
        assert_eq!(format_time(45, 29.97), "00:01.50");
    }

    #[test]
    fn crop_badges() {
        let r = CropRect { x: 320, y: 180, width: 1280, height: 720 };
        assert_eq!(crop_badge(None, None, false), "—  (no crop)");
        assert_eq!(crop_badge(None, Some(r), false), "1280x720");
        assert_eq!(crop_badge(None, Some(r), true), "—  (no crop yet)");
        assert_eq!(crop_badge(Some(r), None, true), "1280x720 @ (320, 180)");
        assert_eq!(crop_field_texts(None, (Some(1920), Some(1080))), ["1920", "1080", "0", "0"]);
        assert_eq!(crop_field_texts(None, (None, None)), ["0", "0", "0", "0"]);
        assert_eq!(crop_field_texts(Some(r), (None, None)), ["1280", "720", "320", "180"]);
    }

    #[test]
    fn crop_field_commit() {
        let full = full_frame_seed(1920, 1080, 4);
        assert_eq!(full, CropRect { x: 0, y: 0, width: 1920, height: 1080 });
        assert_eq!(full_frame_seed(1921, 1081, 2), CropRect { x: 0, y: 0, width: 1920, height: 1080 });
        // Alignment 1 (DXV / HAP / ProRes): pixel-exact, minimum 1 / 0, bounds.
        let c = commit_crop_field(CropField::Width, 1001, full, 1920, 1080, 1);
        assert_eq!((c.corrected, c.was_corrected, c.rect.width, c.rect.height), (1001, false, 1001, 1080));
        let c = commit_crop_field(CropField::Width, 0, full, 1920, 1080, 1);
        assert_eq!((c.corrected, c.was_corrected), (1, true));
        let c = commit_crop_field(CropField::X, 2000, full, 1920, 1080, 1);
        assert_eq!((c.corrected, c.was_corrected, c.rect.x), (0, true, 0));
        let c = commit_crop_field(CropField::Y, -5, full, 1920, 1080, 1);
        assert_eq!((c.corrected, c.was_corrected), (0, true));
        // Alignment 2 (H.264 / HEVC): nearest even, ties up; max floored to even.
        let r = CropRect { x: 0, y: 0, width: 1000, height: 500 };
        let c = commit_crop_field(CropField::Width, 1001, r, 1920, 1080, 2);
        assert_eq!((c.corrected, c.was_corrected), (1002, true));
        let c = commit_crop_field(CropField::X, 921, r, 1921, 1080, 2);
        assert_eq!((c.corrected, c.rect.x, c.rect.width), (920, 920, 1000));
        let c = commit_crop_field(CropField::Height, 5000, r, 1920, 1081, 2);
        assert_eq!((c.corrected, c.rect.height), (1080, 1080));
        // Alignment 4 (Swift's default): round to 4, minimum 4.
        let c = commit_crop_field(CropField::Width, 1, r, 1920, 1080, 4);
        assert_eq!((c.corrected, c.was_corrected), (4, true));
        let c = commit_crop_field(CropField::Width, 1002, r, 1920, 1080, 4);
        assert_eq!(c.corrected, 1004);
        assert_eq!(parse_int("12"), Some(12));
        assert_eq!(parse_int("-3"), Some(-3));
        assert_eq!(parse_int(" 12"), None);
        assert_eq!(parse_int("1.5"), None);
        assert_eq!(parse_int(""), None);
        assert_eq!(flash_alpha(-1.0), 0.0);
        assert!((flash_alpha(0.6) - 0.6).abs() < 1e-6);
        assert_eq!(flash_alpha(1.3), 0.0);
    }

    #[test]
    fn name_commits() {
        assert_eq!(name_commit("   ", "a.mov"), NameCommit::Revert);
        assert_eq!(name_commit(" a.mov ", "a.mov"), NameCommit::Unchanged);
        assert_eq!(name_commit(" b.mov\n", "a.mov"), NameCommit::Set("b.mov".into()));
    }

    #[test]
    fn truncation() {
        let m = |s: &str| s.chars().count() as f32;
        assert_eq!(truncate_middle("abcdef", 6.0, m), "abcdef");
        assert_eq!(truncate_middle("abcdefghij", 5.0, m), "ab…ij");
        assert_eq!(truncate_middle("abcdefghij", 6.0, m), "abc…ij");
        assert_eq!(truncate_middle("abcdefghij", 0.0, m), "…");
        assert_eq!(truncate_tail("abcdefghij", 5.0, m), "abcd…");
    }

    #[test]
    fn click_selection_rules() {
        let order = [1, 2, 3, 4, 5];
        let none = BTreeSet::new();
        assert_eq!(click_selection(&order, &none, None, 3, false, false), (BTreeSet::from([3]), Some(3)));
        let cur = BTreeSet::from([3]);
        assert_eq!(click_selection(&order, &cur, Some(3), 5, true, false), (BTreeSet::from([3, 5]), Some(5)));
        assert_eq!(click_selection(&order, &BTreeSet::from([3, 5]), Some(5), 5, true, false), (BTreeSet::from([3]), Some(5)));
        assert_eq!(click_selection(&order, &cur, Some(3), 1, false, true), (BTreeSet::from([1, 2, 3]), Some(3)));
        assert_eq!(click_selection(&order, &BTreeSet::from([5]), Some(3), 1, true, true), (BTreeSet::from([1, 2, 3, 5]), Some(3)));
        // No anchor: ⇧-click selects the row.
        assert_eq!(click_selection(&order, &none, None, 4, false, true), (BTreeSet::from([4]), Some(4)));
        assert_eq!(context_targets(&BTreeSet::from([1, 2]), 2), BTreeSet::from([1, 2]));
        assert_eq!(context_targets(&BTreeSet::from([1, 2]), 4), BTreeSet::from([4]));
        let mut jobs = vec![job(1), job(2)];
        assert!(!reset_enabled(&jobs, &BTreeSet::from([1, 2]), false));
        jobs[1].status = Status::Done;
        assert!(reset_enabled(&jobs, &BTreeSet::from([1, 2]), false));
        assert!(!reset_enabled(&jobs, &BTreeSet::from([1, 2]), true));
        assert!(!reset_enabled(&jobs, &BTreeSet::from([1]), false));
    }

    #[test]
    fn numbers_and_labels() {
        assert_eq!(format_number(10.0), "10");
        assert_eq!(format_number(10.5), "10.5");
        assert_eq!(format_number(1000.0), "1,000");
        assert_eq!(format_number(1234567.25), "1,234,567.25");
        assert_eq!(parse_number("1,000"), Some(1000.0));
        assert_eq!(parse_number(" 2.5 "), Some(2.5));
        assert_eq!(parse_number("x"), None);
        assert_eq!(stated_by(Some(*b"Hap5")), "HAP");
        assert_eq!(stated_by(Some(*b"ap4x")), "ProRes 4444 XQ");
        assert_eq!(stated_by(Some(*b"hvc1")), "HEVC");
        assert_eq!(stated_by(Some(*b"png ")), "png ");
        assert_eq!(alpha_type_label(AlphaType::Straight), "Straight");
        assert_eq!(h264_profile_label(H264Profile::Main), "Main");
        assert_eq!(percent(1.0), "100%");
    }
}
