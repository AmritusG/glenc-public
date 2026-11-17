//! Auto names and output collisions (Swift GlEnc 1.6.2 `AutoNameEngine.swift`, the collision parts of
//! `EncodeQueue.swift`, `CollisionPrompt.swift`, and the naming parts of `EncodeJob.swift`).
//!
//! Everything here is pure: the file system is reached through [`FileSystem`] ([`RealFileSystem`] in the app,
//! [`MemoryFileSystem`] in tests), so the queue engine can drive [`CollisionSession`] without touching the disk
//! itself.
//!
//! The pieces, in the order the queue uses them:
//! 1. [`suggested_name`] / [`EncodeJob::set_output_name_auto`] — the row's auto name.
//! 2. [`planned_output_path`] — where the row writes before collision handling (fixed folder or the source's folder).
//! 3. [`CollisionSession::begin`] → [`Step`] — at write start: proceed, or ask the user ([`CollisionPrompt`]);
//!    [`CollisionSession::answer`] takes the prompt's answer and remembers "apply to all" for the session.
//! 4. [`EncodeJob::apply_resolution`] — the row bookkeeping (shown name, `pre_collision_name`, status).
//! 5. [`EncodeJob::reset_for_rerun`] — Queue ▸ Reset for Re-run (restores the base name).
//!
//! File-name splitting follows Foundation's `URL.pathExtension` / `deletingPathExtension()` as measured on
//! macOS 27 (Swift 6.4.2): see [`path_extension`] and [`deleting_path_extension`].

use crate::job::{EncodeJob, JobId, PreviewSide, Status};
use crate::settings::{CollisionPolicy, OutputLocation, TrimFilenameFormat};
use glance_encode::codec::{DxvFormat, OutputCodec, OutputContainer};
use glance_encode::frame::CropRect;
use std::collections::{BTreeSet, HashSet};
use std::path::{Component, Path, PathBuf};

/// The row error of a job skipped at the collision prompt (`EncodeQueue.swift:794`).
pub const SKIPPED_MESSAGE: &str = "Skipped — output exists";
/// The row error of a job cancelled at the collision prompt (`EncodeQueue.swift:806`); also what the queue writes on
/// every queued job the cancelled session never reached (`EncodeQueue.swift:681`).
pub const CANCELLED_MESSAGE: &str = "Cancelled";

// MARK: - File system

/// The two file-system questions the naming code asks.
pub trait FileSystem {
    /// `FileManager.fileExists(atPath:)`: true for a file or a directory (symlinks followed).
    fn exists(&self, path: &Path) -> bool;
    /// The entry names in `dir` (`FileManager.contentsOfDirectory(at:includingPropertiesForKeys: nil)`: hidden
    /// files included); empty when the directory cannot be read (Swift's `try? … ?? []`, `AutoNameEngine.swift:240-242`).
    fn file_names(&self, dir: &Path) -> Vec<String>;
}

/// The real disk.
#[derive(Clone, Copy, Debug, Default)]
pub struct RealFileSystem;

impl FileSystem for RealFileSystem {
    fn exists(&self, path: &Path) -> bool {
        path.exists()
    }
    fn file_names(&self, dir: &Path) -> Vec<String> {
        match std::fs::read_dir(dir) {
            Ok(rd) => rd.filter_map(Result::ok).map(|e| e.file_name().to_string_lossy().into_owned()).collect(),
            Err(_) => Vec::new(),
        }
    }
}

/// An in-memory file tree for tests: a set of file paths; every proper ancestor of a file exists as a directory.
#[derive(Clone, Debug, Default)]
pub struct MemoryFileSystem {
    files: BTreeSet<PathBuf>,
}

impl MemoryFileSystem {
    pub fn new() -> MemoryFileSystem {
        MemoryFileSystem::default()
    }
    pub fn with_files<I: IntoIterator<Item = P>, P: Into<PathBuf>>(files: I) -> MemoryFileSystem {
        MemoryFileSystem { files: files.into_iter().map(Into::into).collect() }
    }
    pub fn insert(&mut self, path: impl Into<PathBuf>) {
        self.files.insert(path.into());
    }
    pub fn remove(&mut self, path: &Path) -> bool {
        self.files.remove(path)
    }
}

impl FileSystem for MemoryFileSystem {
    fn exists(&self, path: &Path) -> bool {
        self.files.contains(path) || self.files.iter().any(|f| f != path && f.starts_with(path))
    }
    fn file_names(&self, dir: &Path) -> Vec<String> {
        let mut names = BTreeSet::new();
        for f in &self.files {
            if let Ok(rest) = f.strip_prefix(dir)
                && let Some(Component::Normal(first)) = rest.components().next()
            {
                names.insert(first.to_string_lossy().into_owned());
            }
        }
        names.into_iter().collect()
    }
}

// MARK: - Foundation path pieces

/// The byte index of the extension's dot under Foundation's rules, or `None` when the name has no extension: the
/// last `.` of the name, not the final character, with something other than dots before it (`.mov`, `..mov`, `Clip.`
/// have none).
fn extension_dot(name: &str) -> Option<usize> {
    let dot = name.rfind('.')?;
    if dot + 1 == name.len() || name.as_bytes()[..dot].iter().all(|&b| b == b'.') {
        return None;
    }
    Some(dot)
}

/// Foundation's `URL.pathExtension` of a last path component: the part after [`extension_dot`], or `""` when that
/// part contains an ASCII space (`"a.b c"` → `""`; other white space, e.g. U+00A0, is accepted).
pub fn path_extension(name: &str) -> &str {
    match extension_dot(name) {
        Some(d) if !name[d + 1..].contains(' ') => &name[d + 1..],
        _ => "",
    }
}

/// Foundation's `URL.deletingPathExtension().lastPathComponent`: the name before [`extension_dot`]. Unlike
/// [`path_extension`] this strips an extension containing a space (`"a.b c"` → `"a"` although its extension reads
/// `""`) — Foundation's own inconsistency, mirrored.
pub fn deleting_path_extension(name: &str) -> &str {
    match extension_dot(name) {
        Some(d) => &name[..d],
        None => name,
    }
}

/// `URL.lastPathComponent` of a path (lossy for a name that is not UTF-8; macOS names always are).
pub fn last_path_component(path: &Path) -> String {
    match path.components().next_back() {
        Some(Component::Normal(s)) => s.to_string_lossy().into_owned(),
        Some(Component::RootDir) => "/".to_owned(),
        Some(Component::CurDir) => ".".to_owned(),
        Some(Component::ParentDir) => "..".to_owned(),
        Some(Component::Prefix(p)) => p.as_os_str().to_string_lossy().into_owned(),
        None => String::new(),
    }
}

/// `URL.deletingLastPathComponent()`.
fn parent_dir(path: &Path) -> &Path {
    path.parent().unwrap_or(Path::new(""))
}

/// `URL.standardizedFileURL.path`, lexically: `.` components dropped, `..` removes the component before it (and is
/// dropped at the root), repeated and trailing slashes collapse. Symlinks are not resolved (neither are they by
/// Foundation). A relative path stays relative (Foundation resolves it against the working directory first; the
/// queue only ever compares paths built the same way).
pub fn standardize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => match out.components().next_back() {
                Some(Component::Normal(_)) => {
                    out.pop();
                }
                Some(Component::RootDir | Component::Prefix(_)) => {}
                _ => out.push(".."),
            },
            other => out.push(other.as_os_str()),
        }
    }
    out
}

// MARK: - Auto name (AutoNameEngine.suggestedName)

/// `AutoNameEngine.qualityLabel(for:)` (`AutoNameEngine.swift:287-292`): `DXVFormat.tier` (`DXVFormat.swift:69-74`).
fn quality_label(format: DxvFormat) -> &'static str {
    match format {
        DxvFormat::Dxt1 | DxvFormat::Dxt5 | DxvFormat::Hap1 | DxvFormat::Hap5 | DxvFormat::HapA => "Normal Quality",
        DxvFormat::Ycg6 | DxvFormat::Yg10 | DxvFormat::HapY | DxvFormat::HapM => "High Quality",
    }
}

/// `DXVFormat.label` (`DXVFormat.swift:85-96`).
fn format_label(format: DxvFormat) -> &'static str {
    match format {
        DxvFormat::Hap1 => "Hap1",
        DxvFormat::Hap5 => "Hap5",
        DxvFormat::HapY => "HapY",
        DxvFormat::HapA => "HapA",
        DxvFormat::HapM => "HapM",
        DxvFormat::Dxt1 => "DXT1",
        DxvFormat::Dxt5 => "DXT5",
        DxvFormat::Ycg6 => "YCG6",
        DxvFormat::Yg10 => "YG10",
    }
}

/// `AutoNameEngine.formatTime` (`AutoNameEngine.swift:177-188`): `MM.SS.CC`, centiseconds truncated; fps ≤ 0 (or
/// NaN) gives `00.00.00`; a negative frame clamps to 0. Same IEEE operations as Swift, so the same digits. `%02d`
/// receives a 64-bit `Int` and prints its low 32 bits (measured: 5 000 000 000 minutes print `705032704`), mirrored
/// with `as i32`. Where Swift traps (`Int(Double)` out of range, e.g. fps 1e-300) this saturates.
fn format_time(frame_index: i64, fps: f64) -> String {
    if fps.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater) {
        return "00.00.00".to_owned();
    }
    let t = frame_index as f64 / fps;
    let total_seconds = if t > 0.0 { t } else { 0.0 };
    let minutes = (total_seconds as i64) / 60;
    let seconds_part = total_seconds - (minutes * 60) as f64;
    let seconds = seconds_part as i64;
    let centiseconds = ((seconds_part - seconds as f64) * 100.0) as i64;
    format!("{:02}.{:02}.{:02}", minutes as i32, seconds as i32, centiseconds as i32)
}

/// `AutoNameEngine.suggestedName` (`AutoNameEngine.swift:83-167`): `<stem><codec suffix>[ [WxH]][ [in-out]].<ext>`.
///
/// - stem: the source's last component minus its extension, Foundation's way ([`deleting_path_extension`]):
///   `My.Clip.v2.mov` → `My.Clip.v2`.
/// - suffix (`:98-120`): `ProRes(v)` → `_` + [`ProResVariant::name_token`](glance_encode::codec::ProResVariant::name_token);
///   `_H.264`, `_HEVC`, `_MotionJPEG`; `Dxv(_)` → from **`format`** (not the codec's payload, as Swift): DXV3 →
///   `_DXV Normal Quality` / `_DXV High Quality` + ` With Alpha`; HAP → `_Hap1` / `_Hap5` / `_HapY` / `_HapA` / `_HapM`.
///   (Swift's `outputCodec: nil` takes the same branch as `.dxv`.)
/// - crop (`:130-134`): ` [WxH]` whenever a crop is set, even the full frame or a zero size.
/// - trim (`:136-160`): only when an end is set. in = `in_frame` or 0; out = `out_frame`, else `total_frames - 1` when
///   the total is known and > 0, else in; the two are sorted. [`TrimFilenameFormat::Time`] → `MM.SS.CC-MM.SS.CC`
///   ([`format_time`], fps 0 → `00.00.00-00.00.00`), [`TrimFilenameFormat::FrameIndices`] → `N-M` (fps ignored).
/// - extension: the container's (`mov` / `mp4`).
#[allow(clippy::too_many_arguments)]
pub fn suggested_name(
    source: &Path,
    format: DxvFormat,
    codec: OutputCodec,
    container: OutputContainer,
    in_frame: Option<i64>,
    out_frame: Option<i64>,
    fps: f64,
    total_frames: Option<i64>,
    trim_format: TrimFilenameFormat,
    crop: Option<CropRect>,
) -> String {
    let last = last_path_component(source);
    let stem = deleting_path_extension(&last);

    let mut suffix = match codec {
        OutputCodec::ProRes(v) => format!("_{}", v.name_token()),
        OutputCodec::H264 => "_H.264".to_owned(),
        OutputCodec::Hevc => "_HEVC".to_owned(),
        OutputCodec::Mjpeg => "_MotionJPEG".to_owned(),
        OutputCodec::Dxv(_) => {
            if format.is_hap() {
                format!("_{}", format_label(format))
            } else {
                let mut s = format!("_DXV {}", quality_label(format));
                if format.has_alpha() {
                    s.push_str(" With Alpha");
                }
                s
            }
        }
    };

    if let Some(c) = crop {
        suffix.push_str(&format!(" [{}x{}]", c.width, c.height));
    }

    if in_frame.is_some() || out_frame.is_some() {
        let lo = in_frame.unwrap_or(0);
        let hi = match (out_frame, total_frames) {
            (Some(out), _) => out,
            (None, Some(total)) if total > 0 => total - 1,
            _ => lo,
        };
        let (low_end, high_end) = (lo.min(hi), lo.max(hi));
        let bracket = match trim_format {
            TrimFilenameFormat::Time => format!("{}-{}", format_time(low_end, fps), format_time(high_end, fps)),
            TrimFilenameFormat::FrameIndices => format!("{low_end}-{high_end}"),
        };
        suffix.push_str(&format!(" [{bracket}]"));
    }

    format!("{stem}{suffix}.{}", container.ext())
}

// MARK: - Collision-free names

/// `<stem>_<n>[.<ext>]` next to `path` (`AutoNameEngine.swift:261-262`, `:277`).
fn numbered(dir: &Path, stem: &str, ext: &str, n: impl std::fmt::Display) -> PathBuf {
    dir.join(if ext.is_empty() { format!("{stem}_{n}") } else { format!("{stem}_{n}.{ext}") })
}

/// `AutoNameEngine.collisionFreeURL` (`AutoNameEngine.swift:213-263`), the Auto-rename policy and the prompt's
/// suggested Rename: `path` when nothing exists there; else `<stem>_<N+1>.<ext>` where N is the highest numeric `_N`
/// among the directory's `<stem>_<digits>.<ext>` entries, at least 1. Gaps are NOT filled (`_2`, `_4` → `_5`).
///
/// A middle counts when it is non-empty ASCII digits that fit an `Int` (`"007"` is 7; `_backup`, `_٣` and values past
/// `i64::MAX` are ignored, as Swift's `isNumber` + `Int(_:)`). Stem and extension are Foundation's
/// ([`deleting_path_extension`], [`path_extension`]), so a name like `clip.final cut` numbers as `clip_2` (Swift
/// drops the space-containing extension too). Where Swift traps (a sibling `_9223372036854775807`) this returns
/// `_9223372036854775808`. Names are compared byte-wise; Swift's `hasPrefix` also matches canonically equivalent
/// Unicode (NFC vs NFD), a difference only for a directory holding both forms.
pub fn collision_free_path(path: &Path, fs: &dyn FileSystem) -> PathBuf {
    if !fs.exists(path) {
        return path.to_path_buf();
    }
    let name = last_path_component(path);
    let stem = deleting_path_extension(&name);
    let ext = path_extension(&name);
    let dir = parent_dir(path);
    let prefix = format!("{stem}_");
    let suffix = if ext.is_empty() { String::new() } else { format!(".{ext}") };

    let mut max_n: i64 = 1;
    for sib in fs.file_names(dir) {
        if !sib.starts_with(&prefix) || !sib.ends_with(&suffix) || sib.len() < prefix.len() + suffix.len() {
            continue;
        }
        let middle = &sib[prefix.len()..sib.len() - suffix.len()];
        if !middle.is_empty()
            && middle.bytes().all(|b| b.is_ascii_digit())
            && let Ok(n) = middle.parse::<i64>()
            && n > max_n
        {
            max_n = n;
        }
    }
    numbered(dir, stem, ext, i128::from(max_n) + 1)
}

/// `AutoNameEngine.firstFreeNumberedURL` (`AutoNameEngine.swift:270-281`), the re-run rule: `path` when not taken,
/// else the first `<stem>_N.<ext>` not taken for N = 2, 3, … (gaps filled: `_2`, `_4` taken → `_3`).
pub fn first_free_numbered_path(path: &Path, is_taken: &dyn Fn(&Path) -> bool) -> PathBuf {
    if !is_taken(path) {
        return path.to_path_buf();
    }
    let name = last_path_component(path);
    let stem = deleting_path_extension(&name);
    let ext = path_extension(&name);
    let dir = parent_dir(path);
    for n in 2u64.. {
        let candidate = numbered(dir, stem, ext, n);
        if !is_taken(&candidate) {
            return candidate;
        }
    }
    // Every u64 taken: not reachable in practice (Swift would trap on overflow).
    path.to_path_buf()
}

/// The re-run output (`EncodeQueue.swift:774-779`): [`first_free_numbered_path`] where a path is taken when its
/// [`standardize`]d form is in `reserved` (the paths other queued / encoding rows will write — build it with
/// [`claimed_output_paths`]) or something exists there.
pub fn rerun_output_path(candidate: &Path, fs: &dyn FileSystem, reserved: &HashSet<PathBuf>) -> PathBuf {
    first_free_numbered_path(candidate, &|p| reserved.contains(&standardize(p)) || fs.exists(p))
}

// MARK: - Output folder

/// The folder a row writes into (`EncodeQueue.plannedOutputURL`, `EncodeQueue.swift:488-496`): `fixed_path` when the
/// setting is Fixed, the path is non-empty and something exists there (`fileExists` only: a regular file passes too,
/// and the encode then fails), else the source's folder.
pub fn output_directory(source: &Path, location: OutputLocation, fixed_path: &str, fs: &dyn FileSystem) -> PathBuf {
    if location == OutputLocation::Fixed && !fixed_path.is_empty() && fs.exists(Path::new(fixed_path)) {
        return PathBuf::from(fixed_path);
    }
    parent_dir(source).to_path_buf()
}

/// `EncodeQueue.plannedOutputURL(for:)` (`EncodeQueue.swift:488-496`): where the row will be written before collision
/// handling — [`output_directory`] + the row's `output_name`.
pub fn planned_output_path(job: &EncodeJob, location: OutputLocation, fixed_path: &str, fs: &dyn FileSystem) -> PathBuf {
    output_directory(&job.source, location, fixed_path, fs).join(&job.output_name)
}

/// `EncodeQueue.claimedOutputPaths(excluding:)` (`EncodeQueue.swift:499-502`): the [`standardize`]d planned outputs of
/// every queued or encoding row other than `excluding` — the `reserved` set of [`rerun_output_path`] /
/// [`CollisionSession::begin`].
pub fn claimed_output_paths<'a>(
    jobs: impl IntoIterator<Item = &'a EncodeJob>,
    excluding: JobId,
    location: OutputLocation,
    fixed_path: &str,
    fs: &dyn FileSystem,
) -> HashSet<PathBuf> {
    jobs.into_iter()
        .filter(|j| j.id != excluding && matches!(j.status, Status::Queued | Status::Encoding))
        .map(|j| standardize(&planned_output_path(j, location, fixed_path, fs)))
        .collect()
}

// MARK: - Collision session (EncodeQueue.resolveCollision)

/// What a job does about its output (`EncodeQueue.CollisionResolution`, `EncodeQueue.swift:1047-1054`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// Write here (the candidate, or a renamed path).
    Proceed(PathBuf),
    /// Skip this job: it fails with [`SKIPPED_MESSAGE`]; the batch goes on.
    Skip,
    /// Cancel the batch: this job fails with [`CANCELLED_MESSAGE`], and so does every queued job after it.
    CancelSession,
}

/// The collision prompt the UI shows ("Output file already exists"; `CollisionPrompt.swift:33-57`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CollisionPrompt {
    /// The output that already exists.
    pub existing: PathBuf,
    /// What Rename writes: [`collision_free_path`] computed when the prompt is raised (`EncodeQueue.swift:1082`).
    pub suggested_rename: PathBuf,
}

/// The prompt's buttons (`CollisionDecision`, `CollisionPromptView.swift:101-118`). Rename writes the prompt's
/// `suggested_rename`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PromptAnswer {
    Overwrite,
    Rename,
    Skip,
    Cancel,
}

/// The "apply to all" choice remembered for the rest of the session (`EncodeQueue.CollisionDecisionBase`,
/// `EncodeQueue.swift:113-117`). Rename is remembered as AutoRename: each later collision gets its own fresh
/// [`collision_free_path`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RememberedChoice {
    Overwrite,
    AutoRename,
    Skip,
}

/// One step of the collision check for a job.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
    /// Decided without the user.
    Done(Resolution),
    /// Show the prompt, then call [`CollisionSession::answer`].
    Ask(CollisionPrompt),
}

/// The collision state of one Encode Queue run (`EncodeQueue.sessionCollisionOverride`, `EncodeQueue.swift:106`):
/// create a fresh one (or [`reset`](Self::reset)) when a run starts (`EncodeQueue.swift:667`), then for each job at
/// write start call [`begin`](Self::begin), and [`answer`](Self::answer) when it asks.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CollisionSession {
    remembered: Option<RememberedChoice>,
    cancelled: bool,
}

impl CollisionSession {
    pub fn new() -> CollisionSession {
        CollisionSession::default()
    }
    /// A new run: no remembered choice (`EncodeQueue.swift:665-667`).
    pub fn reset(&mut self) {
        *self = CollisionSession::default();
    }
    /// The "apply to all" choice in force, if any.
    pub fn remembered(&self) -> Option<RememberedChoice> {
        self.remembered
    }
    /// Whether the user picked Cancel at a prompt this run (Swift cancels the run's task: the remaining queued jobs
    /// fail with [`CANCELLED_MESSAGE`], `EncodeQueue.swift:672-684`, `:803-808`).
    pub fn is_cancelled(&self) -> bool {
        self.cancelled
    }

    /// The collision check at write start (`EncodeQueue.encodeOne`, `EncodeQueue.swift:766-785`, and
    /// `resolveCollision`, `:1060-1091`). `candidate` is [`planned_output_path`]; `reserved` is
    /// [`claimed_output_paths`] for this row.
    ///
    /// - A re-run never asks and ignores the policy and the remembered choice: [`rerun_output_path`] (first free
    ///   `_N`, N ≥ 2, avoiding existing files and `reserved`).
    /// - A first run ignores `reserved`. Nothing at `candidate` → proceed there. Else the remembered choice wins over
    ///   the policy; else Overwrite → `candidate`, AutoRename → [`collision_free_path`], Ask → [`Step::Ask`] with that
    ///   same collision-free path as the suggested rename.
    pub fn begin(&self, candidate: &Path, policy: CollisionPolicy, is_rerun: bool, fs: &dyn FileSystem, reserved: &HashSet<PathBuf>) -> Step {
        if is_rerun {
            return Step::Done(Resolution::Proceed(rerun_output_path(candidate, fs, reserved)));
        }
        if !fs.exists(candidate) {
            return Step::Done(Resolution::Proceed(candidate.to_path_buf()));
        }
        if let Some(choice) = self.remembered {
            return Step::Done(apply_remembered(choice, candidate, fs));
        }
        match policy {
            CollisionPolicy::Overwrite => Step::Done(Resolution::Proceed(candidate.to_path_buf())),
            CollisionPolicy::AutoRename => Step::Done(Resolution::Proceed(collision_free_path(candidate, fs))),
            CollisionPolicy::Ask => Step::Ask(CollisionPrompt { existing: candidate.to_path_buf(), suggested_rename: collision_free_path(candidate, fs) }),
        }
    }

    /// The user's answer to `prompt` (`EncodeQueue.swift:1096-1112`). With `apply_to_all`, Overwrite / Rename / Skip
    /// are remembered for the rest of the run (Rename as AutoRename); Cancel never is (the UI also passes false).
    /// Overwrite → `prompt.existing`, Rename → `prompt.suggested_rename` (as computed when asked, not recomputed),
    /// Skip → [`Resolution::Skip`], Cancel → [`Resolution::CancelSession`].
    pub fn answer(&mut self, prompt: &CollisionPrompt, answer: PromptAnswer, apply_to_all: bool) -> Resolution {
        if apply_to_all {
            match answer {
                PromptAnswer::Overwrite => self.remembered = Some(RememberedChoice::Overwrite),
                PromptAnswer::Rename => self.remembered = Some(RememberedChoice::AutoRename),
                PromptAnswer::Skip => self.remembered = Some(RememberedChoice::Skip),
                PromptAnswer::Cancel => {}
            }
        }
        match answer {
            PromptAnswer::Overwrite => Resolution::Proceed(prompt.existing.clone()),
            PromptAnswer::Rename => Resolution::Proceed(prompt.suggested_rename.clone()),
            PromptAnswer::Skip => Resolution::Skip,
            PromptAnswer::Cancel => {
                self.cancelled = true;
                Resolution::CancelSession
            }
        }
    }
}

/// `EncodeQueue.applyDecision` (`EncodeQueue.swift:1115-1122`).
fn apply_remembered(choice: RememberedChoice, candidate: &Path, fs: &dyn FileSystem) -> Resolution {
    match choice {
        RememberedChoice::Overwrite => Resolution::Proceed(candidate.to_path_buf()),
        RememberedChoice::AutoRename => Resolution::Proceed(collision_free_path(candidate, fs)),
        RememberedChoice::Skip => Resolution::Skip,
    }
}

// MARK: - Row bookkeeping

impl EncodeJob {
    /// A new row with its auto name filled in, as Swift's `EncodeJob.init` does (`EncodeJob.swift:319-337`; no trim
    /// or fps yet, so the trim format does not matter). [`EncodeJob::new`] leaves `output_name` empty.
    pub fn with_auto_name(id: JobId, source: PathBuf, settings: crate::job::JobSettings) -> EncodeJob {
        let mut job = EncodeJob::new(id, source, settings);
        job.set_output_name_auto(TrimFilenameFormat::Time);
        job
    }

    /// [`suggested_name`] for the row's current source, format, codec, container, trim, fps (unknown → 0), frame
    /// count and crop (`EncodeJob.setOutputNameAuto`, `EncodeJob.swift:252-271`).
    pub fn auto_name(&self, trim_format: TrimFilenameFormat) -> String {
        suggested_name(
            &self.source,
            self.settings.format,
            self.settings.codec,
            self.settings.container,
            self.in_frame,
            self.out_frame,
            self.source_fps.unwrap_or(0.0),
            self.source_frame_count.map(|n| i64::try_from(n).unwrap_or(i64::MAX)),
            trim_format,
            self.crop,
        )
    }

    /// `EncodeJob.setOutputNameAuto` (`EncodeJob.swift:252-271`): overwrite `output_name` with the auto name
    /// (no override check — see [`refresh_auto_name_if_needed`](Self::refresh_auto_name_if_needed)).
    pub fn set_output_name_auto(&mut self, trim_format: TrimFilenameFormat) {
        self.output_name = self.auto_name(trim_format);
    }

    /// `EncodeJob.resetOutputNameToAuto` (`EncodeJob.swift:275-280`), the row's ↻ button: drop the manual override and
    /// take the auto name. `pre_collision_name` is left as it is (as Swift).
    pub fn reset_output_name_to_auto(&mut self, trim_format: TrimFilenameFormat) {
        self.output_name_overridden = false;
        self.set_output_name_auto(trim_format);
    }

    /// The per-row part of `EncodeQueue.refreshAutoNameIfNeeded` (`EncodeQueue.swift:451-458`): take the auto name
    /// unless the user renamed the row. Returns whether it did.
    pub fn refresh_auto_name_if_needed(&mut self, trim_format: TrimFilenameFormat) -> bool {
        if self.output_name_overridden {
            return false;
        }
        self.set_output_name_auto(trim_format);
        true
    }

    /// The per-row part of `EncodeQueue.resetJobs` (`EncodeQueue.swift:511-533`), Reset for Re-run: a finished row
    /// (done / failed) goes back to queued with progress, error, audio warning and output cleared, the preview on the
    /// source, and `is_rerun` set. A collision-renamed name goes back to its base (`pre_collision_name`, then
    /// cleared) and the override is dropped; then, when the row is not overridden, the auto name is refreshed —
    /// so a base name that was itself a manual rename is replaced by the auto name (Swift does the same). A manual
    /// rename with no collision rename is kept. Queued / encoding rows are untouched. Returns whether it reset.
    pub fn reset_for_rerun(&mut self, trim_format: TrimFilenameFormat) -> bool {
        if !self.is_finished() {
            return false;
        }
        self.status = Status::Queued;
        self.progress = 0.0;
        self.error = None;
        self.audio_warning = None;
        self.output_path = None;
        self.preview_side = PreviewSide::Source;
        self.is_rerun = true;
        if let Some(base) = self.pre_collision_name.take() {
            self.output_name = base;
            self.output_name_overridden = false;
        }
        self.refresh_auto_name_if_needed(trim_format);
        true
    }

    /// The row side of a [`Resolution`] (`EncodeQueue.encodeOne`, `EncodeQueue.swift:786-835`), `initial` being the
    /// [`planned_output_path`] the check started from:
    ///
    /// - `Proceed(out)`: when `out` differs from `initial`, the row shows the real name (`output_name` = `out`'s last
    ///   component, overridden) and remembers the name it had in `pre_collision_name` unless one is already
    ///   remembered; then the row starts encoding (progress 0, no error, `is_rerun` cleared). Returns `Some(out)`.
    /// - `Skip`: failed with [`SKIPPED_MESSAGE`]. `CancelSession`: failed with [`CANCELLED_MESSAGE`]. Returns `None`.
    pub fn apply_resolution(&mut self, initial: &Path, resolution: &Resolution) -> Option<PathBuf> {
        match resolution {
            Resolution::Proceed(out) => {
                if out.as_path() != initial {
                    if self.pre_collision_name.is_none() {
                        self.pre_collision_name = Some(self.output_name.clone());
                    }
                    self.output_name = last_path_component(out);
                    self.output_name_overridden = true;
                }
                self.status = Status::Encoding;
                self.progress = 0.0;
                self.error = None;
                self.is_rerun = false;
                Some(out.clone())
            }
            Resolution::Skip => {
                self.status = Status::Failed;
                self.error = Some(SKIPPED_MESSAGE.to_owned());
                None
            }
            Resolution::CancelSession => {
                self.status = Status::Failed;
                self.error = Some(CANCELLED_MESSAGE.to_owned());
                None
            }
        }
    }
}
