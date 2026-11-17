//! The queue (Swift GlEnc 1.6.2 `EncodeQueue.swift`): rows added from files, probed in the background, edited one
//! at a time or in batch (only queued / failed rows change), encoded one at a time in list order on a worker
//! thread, with per-row and whole-session cancel, output collisions resolved at write start, re-runs, and the
//! defaults for new files (the settings bar when fewer than two rows are selected).
//!
//! Everything here runs on the UI thread except the encode itself and the probes, which report back through
//! channels drained by [`Queue::poll`] (call it every frame).

use crate::job::{EncodeJob, JobId, JobSettings, PreviewSide, Status};
use crate::naming;
use crate::settings::{AlphaMode, Change, CollisionPolicy, OutputLocation, QualityTier, Settings, alpha_of, format_of, tier_of};
use glance_encode::audio::AudioPlan;
use glance_encode::codec::OutputCodec;
use glance_encode::frame::CropRect;
use glance_encode::{EncodeOutcome, EncodeRequest};
use glance_media::AlphaReport;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};

/// What the probe of a newly added file found (`EncodeQueue.swift:383-443`).
#[derive(Clone, Debug)]
pub struct Probe {
    pub id: JobId,
    pub has_alpha: Option<bool>,
    pub has_audio: bool,
    pub alpha_report: Option<AlphaReport>,
    /// (width, height, fps, frames) from the encode reader, or the reader's refusal.
    pub timing: Result<(u32, u32, f64, u64), String>,
}

/// The collision prompt the UI shows (Swift's `CollisionPrompt`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CollisionPrompt {
    pub job: JobId,
    pub existing: PathBuf,
    pub suggested_rename: PathBuf,
}

/// The user's answer to a [`CollisionPrompt`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CollisionDecision {
    Overwrite,
    Rename(PathBuf),
    Skip,
    Cancel,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SessionOverride {
    Overwrite,
    AutoRename,
    Skip,
}

struct Running {
    id: JobId,
    out: PathBuf,
    cancel: Arc<AtomicBool>,
    progress: Arc<AtomicU64>,
    done: Receiver<Result<EncodeOutcome, glance_encode::EncodeError>>,
}

/// The encode session started by "Encode Queue".
struct Session {
    /// The queued rows at the start, in list order (rows added later are not part of it).
    ids: Vec<JobId>,
    next: usize,
    cancelled: bool,
    override_: Option<SessionOverride>,
    running: Option<Running>,
    /// Waiting for the user's answer to this prompt (the row to encode next).
    asking: Option<(JobId, PathBuf)>,
}

/// The encode function (the engine; tests put a stub here).
pub type Encoder = Arc<dyn Fn(&EncodeRequest, &dyn Fn(f64), &AtomicBool) -> Result<EncodeOutcome, glance_encode::EncodeError> + Send + Sync>;
/// The probe function (the real one opens the file; tests put a stub here).
pub type Prober = Arc<dyn Fn(JobId, &Path) -> Probe + Send + Sync>;

/// The queue.
pub struct Queue {
    pub jobs: Vec<EncodeJob>,
    next_id: JobId,
    /// The primary selection: drives the preview.
    pub selected: Option<JobId>,
    /// Every selected row.
    pub selected_ids: BTreeSet<JobId>,
    pub settings: Settings,
    session: Option<Session>,
    pub prompt: Option<CollisionPrompt>,
    probes: (Sender<Probe>, Receiver<Probe>),
    encoder: Encoder,
    prober: Prober,
    /// The writer string (`GlEnc <version>`) stamped into DXV / HAP files.
    pub writer_version: String,
    /// Preferences ▸ Advanced ▸ "Experimental: Refined BC4 endpoint search" (session only, off at launch; read when
    /// an encode starts, as Swift reads `BC4Config.useRefinement` when each encoder is made).
    pub refined_bc4: bool,
    /// The crop being edited: the row and the rectangle not yet applied.
    pub crop_edit: Option<(JobId, Option<CropRect>)>,
    crop_prior_pane: Option<bool>,
}

impl Queue {
    pub fn new(settings: Settings, encoder: Encoder, prober: Prober, writer_version: String) -> Queue {
        Queue {
            jobs: Vec::new(),
            next_id: 1,
            selected: None,
            selected_ids: BTreeSet::new(),
            settings,
            session: None,
            prompt: None,
            probes: channel(),
            encoder,
            prober,
            writer_version,
            refined_bc4: false,
            crop_edit: None,
            crop_prior_pane: None,
        }
    }

    pub fn is_encoding(&self) -> bool {
        self.session.is_some()
    }

    pub fn job(&self, id: JobId) -> Option<&EncodeJob> {
        self.jobs.iter().find(|j| j.id == id)
    }

    fn job_mut(&mut self, id: JobId) -> Option<&mut EncodeJob> {
        self.jobs.iter_mut().find(|j| j.id == id)
    }

    // MARK: - Selection (`EncodeQueue.swift:60-110`)

    /// Set the selection; the primary row stays when still selected, else the first newly selected row in list order.
    pub fn select(&mut self, ids: BTreeSet<JobId>) {
        if ids.is_empty() {
            self.selected_ids.clear();
            self.selected = None;
            return;
        }
        let old = std::mem::take(&mut self.selected_ids);
        self.selected_ids = ids;
        if let Some(p) = self.selected
            && self.selected_ids.contains(&p)
        {
            return;
        }
        let added: BTreeSet<JobId> = self.selected_ids.difference(&old).copied().collect();
        let pool = if added.is_empty() { self.selected_ids.clone() } else { added };
        self.selected = self.jobs.iter().find(|j| pool.contains(&j.id)).map(|j| j.id).or_else(|| pool.iter().next().copied());
    }

    /// Select one row (a plain click).
    pub fn select_one(&mut self, id: JobId) {
        self.selected = Some(id);
        self.selected_ids = BTreeSet::from([id]);
    }

    pub fn is_batch(&self) -> bool {
        self.selected_ids.len() >= 2
    }

    pub fn select_all(&mut self) {
        self.select(self.jobs.iter().map(|j| j.id).collect());
    }

    pub fn collapse_to_primary(&mut self) {
        match self.selected {
            Some(p) => self.selected_ids = BTreeSet::from([p]),
            None => self.selected_ids.clear(),
        }
    }

    /// Queue ▸ Select Finished Clips (⌥⌘A).
    pub fn select_finished(&mut self) {
        self.select(self.jobs.iter().filter(|j| j.is_finished()).map(|j| j.id).collect());
    }

    pub fn selected_job(&self) -> Option<&EncodeJob> {
        self.selected.and_then(|id| self.job(id))
    }

    pub fn selected_jobs(&self) -> Vec<&EncodeJob> {
        self.jobs.iter().filter(|j| self.selected_ids.contains(&j.id)).collect()
    }

    // MARK: - Defaults for new files (`EncodeQueue.swift:605-643`)

    /// The settings bar's values when it edits the defaults.
    pub fn default_settings(&self) -> JobSettings {
        let v = self.settings.values();
        let format = format_of(v.default_quality, v.default_alpha);
        let codec = match v.default_output_codec {
            OutputCodec::Dxv(_) => OutputCodec::Dxv(format),
            c => c,
        };
        let container = if codec.allowed_containers().contains(&v.default_output_container) {
            v.default_output_container
        } else {
            glance_encode::codec::OutputContainer::Mov
        };
        let mut s = JobSettings {
            format,
            codec,
            container,
            video: v.default_video_settings,
            hap_chunks: v.default_hap_chunks,
            audio_enabled: v.default_audio_enabled,
            audio_rate: v.default_audio_rate,
            output_size: v.default_output_size,
            resize_quality: v.default_resize_quality,
            aspect: v.default_aspect_mode,
            alpha_type: v.default_source_alpha_type,
        };
        s.clamp_audio_rate();
        s
    }

    /// Store new defaults, key by key, only where they changed.
    pub fn set_default_settings(&mut self, n: JobSettings) {
        let v = self.settings.values().clone();
        let (tier, alpha): (QualityTier, AlphaMode) = (tier_of(n.format), alpha_of(n.format));
        let mut changes = Vec::new();
        if v.default_quality != tier {
            changes.push(Change::DefaultQuality(tier));
        }
        if v.default_alpha != alpha {
            changes.push(Change::DefaultAlpha(alpha));
        }
        if v.default_output_codec != n.codec {
            changes.push(Change::DefaultOutputCodec(n.codec));
        }
        if v.default_output_container != n.container {
            changes.push(Change::DefaultOutputContainer(n.container));
        }
        if v.default_video_settings != n.video {
            changes.push(Change::DefaultVideoSettings(n.video));
        }
        if v.default_hap_chunks != n.hap_chunks {
            changes.push(Change::DefaultHapChunks(n.hap_chunks));
        }
        if v.default_audio_enabled != n.audio_enabled {
            changes.push(Change::DefaultAudioEnabled(n.audio_enabled));
        }
        if v.default_audio_rate != n.audio_rate {
            changes.push(Change::DefaultAudioRate(n.audio_rate));
        }
        if v.default_output_size != n.output_size {
            changes.push(Change::DefaultOutputSize(n.output_size));
        }
        if v.default_resize_quality != n.resize_quality {
            changes.push(Change::DefaultResizeQuality(n.resize_quality));
        }
        if v.default_aspect_mode != n.aspect {
            changes.push(Change::DefaultAspectMode(n.aspect));
        }
        if v.default_source_alpha_type != n.alpha_type {
            changes.push(Change::DefaultSourceAlphaType(n.alpha_type));
        }
        for c in changes {
            self.settings.set(c);
        }
    }

    // MARK: - Adding (`EncodeQueue.swift:330-443`)

    /// Add one row per file with the defaults for new files, probe each in the background, and select the first
    /// new row when nothing was selected.
    pub fn add(&mut self, paths: &[PathBuf]) {
        let defaults = self.default_settings();
        let first = self.jobs.len();
        for p in paths {
            let id = self.next_id;
            self.next_id = self.next_id.saturating_add(1);
            let mut job = EncodeJob::new(id, p.clone(), defaults.clone());
            self.refresh_name(&mut job);
            self.jobs.push(job);
            let (tx, prober, path) = (self.probes.0.clone(), self.prober.clone(), p.clone());
            std::thread::spawn(move || {
                let _ = tx.send(prober(id, &path));
            });
        }
        if self.selected.is_none()
            && let Some(j) = self.jobs.get(first)
        {
            let id = j.id;
            self.select_one(id);
        }
    }

    fn refresh_name(&self, job: &mut EncodeJob) {
        if !job.output_name_overridden {
            job.output_name = job.auto_name(self.settings.values().trim_filename_format);
        }
    }

    /// Re-derive a row's auto name (after a setting, trim, crop or timing change) unless the user edited it.
    pub fn refresh_auto_name(&mut self, id: JobId) {
        let fmt = self.settings.values().trim_filename_format;
        if let Some(j) = self.job_mut(id)
            && !j.output_name_overridden
        {
            j.output_name = j.auto_name(fmt);
        }
    }

    /// The user typed a name: it sticks until reset.
    pub fn set_output_name(&mut self, id: JobId, name: String) {
        if let Some(j) = self.job_mut(id) {
            j.output_name = name;
            j.output_name_overridden = true;
        }
    }

    /// The ↻ button: back to the auto name.
    pub fn reset_output_name(&mut self, id: JobId) {
        if let Some(j) = self.job_mut(id) {
            j.output_name_overridden = false;
        }
        self.refresh_auto_name(id);
    }

    fn apply_probe(&mut self, p: Probe) {
        let Some(j) = self.job_mut(p.id) else { return };
        let choosable = p.alpha_report.is_some_and(|r| r.rule == glance_media::AlphaRule::Choosable);
        j.source_has_alpha = p.has_alpha.or(if choosable { Some(true) } else { None });
        j.source_has_audio = Some(p.has_audio);
        j.alpha_report = p.alpha_report;
        match p.timing {
            Ok((w, h, fps, n)) => {
                j.source_width.get_or_insert(w);
                j.source_height.get_or_insert(h);
                let changed = j.source_fps.is_none() || j.source_frame_count.is_none();
                j.source_fps.get_or_insert(fps);
                j.source_frame_count.get_or_insert(n);
                if changed {
                    self.refresh_auto_name(p.id);
                }
            }
            Err(e) => {
                j.status = Status::Failed;
                j.error = Some(format!("Unusable source: {e}"));
            }
        }
    }

    // MARK: - Rows (`EncodeQueue.swift:451-552`)

    /// Remove a row (not while it encodes); the selection moves to the row that took its place.
    pub fn remove(&mut self, id: JobId) {
        let Some(i) = self.jobs.iter().position(|j| j.id == id) else { return };
        if self.jobs[i].status == Status::Encoding {
            return;
        }
        // Swift 1.6.2 leaves a crop edit of a removed row open, so Edit… stays disabled on every other row; the
        // family fixes the Swift apps' quirks (glance-core ROADMAP, "the quirks of the Swift apps are fixed").
        if self.crop_edit.is_some_and(|(row, _)| row == id) {
            self.cancel_crop_edit();
        }
        let was = self.selected == Some(id);
        self.jobs.remove(i);
        // Swift's `selectedJobIDs.remove(id)` runs that property's didSet (`EncodeQueue.swift:467`, `:144-157`): a
        // removed primary hands over to the first remaining selected row.
        if self.selected_ids.contains(&id) {
            let mut rest = self.selected_ids.clone();
            rest.remove(&id);
            self.select(rest);
        }
        if was {
            // `selectedJobID = jobs[i].id` (`EncodeQueue.swift:472-480`): its didSet (`:129-138`) collapses the
            // selection only when that row is outside it, so a multi-selection survives removing its primary.
            let next = self.jobs.get(i).or(self.jobs.last()).map(|j| j.id);
            match next {
                Some(n) if self.selected_ids.contains(&n) => self.selected = Some(n),
                Some(n) => self.select_one(n),
                None => self.select(BTreeSet::new()),
            }
        }
    }

    /// The path a row writes before collision handling: the fixed folder when set and existing, else beside the source.
    pub fn planned_output(&self, job: &EncodeJob) -> PathBuf {
        let v = self.settings.values();
        let fixed = &v.fixed_output_path;
        if v.output_location == OutputLocation::Fixed && !fixed.is_empty() && Path::new(fixed).exists() {
            return Path::new(fixed).join(&job.output_name);
        }
        job.default_output_path()
    }

    /// The paths other queued / encoding rows will write.
    fn claimed(&self, except: JobId) -> BTreeSet<PathBuf> {
        self.jobs
            .iter()
            .filter(|j| j.id != except && matches!(j.status, Status::Queued | Status::Encoding))
            .map(|j| naming::standardize(&self.planned_output(j)))
            .collect()
    }

    /// Reset finished rows for a re-run (Reset Selected / Reset All Finished / Reset for Re-run).
    pub fn reset_jobs(&mut self, ids: &BTreeSet<JobId>) -> usize {
        let mut count = 0;
        let mut refresh = Vec::new();
        for j in self.jobs.iter_mut().filter(|j| ids.contains(&j.id) && j.is_finished()) {
            j.status = Status::Queued;
            j.progress = 0.0;
            j.error = None;
            j.audio_warning = None;
            j.output_path = None;
            j.preview_side = PreviewSide::Source;
            j.is_rerun = true;
            if let Some(base) = j.pre_collision_name.take() {
                j.output_name = base;
                j.output_name_overridden = false;
            }
            if !j.output_name_overridden {
                refresh.push(j.id);
            }
            count += 1;
        }
        for id in refresh {
            self.refresh_auto_name(id);
        }
        count
    }

    pub fn reset_selected(&mut self) -> usize {
        let ids = self.selected_ids.clone();
        self.reset_jobs(&ids)
    }

    pub fn reset_all_finished(&mut self) -> usize {
        let ids = self.jobs.iter().map(|j| j.id).collect();
        self.reset_jobs(&ids)
    }

    /// Retry (a failed row's button, `JobCardView.swift:1171-1177`): queued again, NOT marked a re-run, so the first-run
    /// collision policy applies (Reset for Re-run marks it).
    pub fn retry(&mut self, id: JobId) {
        if let Some(j) = self.job_mut(id)
            && j.status == Status::Failed
        {
            j.status = Status::Queued;
            j.progress = 0.0;
            j.error = None;
            j.output_path = None;
        }
    }

    pub fn has_finished(&self) -> bool {
        self.jobs.iter().any(EncodeJob::is_finished)
    }

    pub fn selection_has_finished(&self) -> bool {
        self.selected_jobs().iter().any(|j| j.is_finished())
    }

    /// Clear Completed: done and failed rows go.
    pub fn clear_completed(&mut self) {
        self.jobs.retain(|j| !j.is_finished());
        let live: BTreeSet<JobId> = self.jobs.iter().map(|j| j.id).collect();
        let pruned: BTreeSet<JobId> = self.selected_ids.intersection(&live).copied().collect();
        if pruned != self.selected_ids {
            self.select(pruned);
        }
    }

    /// Overall progress (done rows count 1, the encoding row its progress), `None` for an empty queue.
    pub fn overall_progress(&self) -> Option<f64> {
        if self.jobs.is_empty() {
            return None;
        }
        let total: f64 = self
            .jobs
            .iter()
            .map(|j| match j.status {
                Status::Done => 1.0,
                Status::Encoding => j.progress,
                _ => 0.0,
            })
            .sum();
        Some(total / self.jobs.len() as f64)
    }

    // MARK: - Editing (`EncodeQueue.swift:560-600`)

    /// Apply an edit to rows that are queued or failed; locked rows are skipped; names follow when the codec,
    /// format or container changed.
    pub fn apply_settings(&mut self, ids: &BTreeSet<JobId>, edit: &dyn Fn(&mut JobSettings, Option<bool>)) {
        let mut renamed = Vec::new();
        for j in self.jobs.iter_mut().filter(|j| ids.contains(&j.id) && j.is_mutable()) {
            let before = j.settings.clone();
            let mut after = before.clone();
            edit(&mut after, j.source_has_alpha);
            if after != before {
                if after.affects_auto_name(&before) {
                    renamed.push(j.id);
                }
                j.settings = after;
            }
        }
        for id in renamed {
            self.refresh_auto_name(id);
        }
    }

    /// The settings bar: the selected rows with 2+ selected, else the defaults for new files.
    pub fn apply_from_settings_bar(&mut self, edit: &dyn Fn(&mut JobSettings, Option<bool>)) {
        if self.is_batch() {
            let ids = self.selected_ids.clone();
            self.apply_settings(&ids, edit);
        } else {
            let mut s = self.default_settings();
            edit(&mut s, None);
            self.set_default_settings(s);
        }
    }

    /// Queue ▸ Change All Clips.
    pub fn apply_to_all(&mut self, edit: &dyn Fn(&mut JobSettings, Option<bool>)) {
        let ids = self.jobs.iter().map(|j| j.id).collect();
        self.apply_settings(&ids, edit);
    }

    /// Set a row's trim (inclusive frames); the name follows.
    pub fn set_trim(&mut self, id: JobId, in_frame: Option<i64>, out_frame: Option<i64>) {
        if let Some(j) = self.job_mut(id)
            && j.is_mutable()
        {
            j.in_frame = in_frame;
            j.out_frame = out_frame;
        }
        self.refresh_auto_name(id);
    }

    pub fn set_preview_side(&mut self, id: JobId, side: PreviewSide) {
        if let Some(j) = self.job_mut(id) {
            j.preview_side = side;
        }
    }

    // MARK: - Crop edit (`EncodeQueue.swift:160-260`)

    pub fn begin_crop_edit(&mut self, id: JobId) {
        if self.crop_edit.is_some() {
            self.cancel_crop_edit();
        }
        let Some(j) = self.job(id) else { return };
        self.crop_edit = Some((id, j.crop));
        let prior = self.settings.values().preview_pane_visible_by_default;
        self.crop_prior_pane = Some(prior);
        self.settings.set(Change::PreviewPaneVisibleByDefault(true));
    }

    pub fn set_pending_crop(&mut self, r: Option<CropRect>) {
        if let Some((_, c)) = self.crop_edit.as_mut() {
            *c = r;
        }
    }

    pub fn apply_crop_edit(&mut self) {
        if let Some((id, r)) = self.crop_edit
            && let Some(j) = self.job_mut(id)
        {
            j.crop = r;
            self.refresh_auto_name(id);
        }
        self.end_crop_edit();
    }

    pub fn clear_crop_edit(&mut self) {
        if let Some((id, _)) = self.crop_edit
            && let Some(j) = self.job_mut(id)
        {
            j.crop = None;
            self.refresh_auto_name(id);
        }
        self.end_crop_edit();
    }

    pub fn cancel_crop_edit(&mut self) {
        self.end_crop_edit();
    }

    fn end_crop_edit(&mut self) {
        self.crop_edit = None;
        if let Some(prior) = self.crop_prior_pane.take() {
            self.settings.set(Change::PreviewPaneVisibleByDefault(prior));
        }
    }

    // MARK: - Encoding (`EncodeQueue.swift:660-1060`)

    /// Encode Queue: the queued rows, one at a time, in list order.
    pub fn encode_all(&mut self) {
        if self.session.is_some() {
            return;
        }
        let ids: Vec<JobId> = self.jobs.iter().filter(|j| j.status == Status::Queued).map(|j| j.id).collect();
        if ids.is_empty() {
            return;
        }
        self.session = Some(Session { ids, next: 0, cancelled: false, override_: None, running: None, asking: None });
    }

    /// Cancel one row: a queued row fails as "Cancelled"; the encoding row stops within a frame.
    pub fn cancel(&mut self, id: JobId) {
        let running = self.session.as_ref().and_then(|s| s.running.as_ref()).filter(|r| r.id == id).map(|r| r.cancel.clone());
        if let Some(c) = running {
            c.store(true, Ordering::Relaxed);
            return;
        }
        if let Some(j) = self.job_mut(id)
            && j.status == Status::Queued
        {
            j.status = Status::Failed;
            j.error = Some("Cancelled".into());
        }
    }

    /// Cancel All (⌘.): the session stops, the encoding row stops, every queued row fails as "Cancelled".
    pub fn cancel_all(&mut self) {
        if let Some(s) = self.session.as_mut() {
            s.cancelled = true;
            if let Some(r) = s.running.as_ref() {
                r.cancel.store(true, Ordering::Relaxed);
            }
        }
        for j in self.jobs.iter_mut().filter(|j| j.status == Status::Queued) {
            j.status = Status::Failed;
            j.error = Some("Cancelled".into());
        }
        if let Some((id, _)) = self.session.as_mut().and_then(|s| s.asking.take()) {
            self.prompt = None;
            self.fail(id, "Cancelled");
        }
    }

    fn fail(&mut self, id: JobId, why: &str) {
        if let Some(j) = self.job_mut(id) {
            j.status = Status::Failed;
            j.error = Some(why.into());
        }
    }

    /// The user answered the collision prompt (`resolveCollision`'s `.ask` branch).
    pub fn answer_prompt(&mut self, decision: CollisionDecision, apply_to_all: bool) {
        self.prompt = None;
        let Some(s) = self.session.as_mut() else { return };
        let Some((id, initial)) = s.asking.take() else { return };
        if apply_to_all {
            s.override_ = match decision {
                CollisionDecision::Overwrite => Some(SessionOverride::Overwrite),
                CollisionDecision::Rename(_) => Some(SessionOverride::AutoRename),
                CollisionDecision::Skip => Some(SessionOverride::Skip),
                CollisionDecision::Cancel => s.override_,
            };
        }
        match decision {
            CollisionDecision::Overwrite => self.start(id, initial.clone(), initial),
            CollisionDecision::Rename(p) => self.start(id, initial, p),
            CollisionDecision::Skip => self.fail(id, "Skipped — output exists"),
            CollisionDecision::Cancel => {
                self.fail(id, "Cancelled");
                if let Some(s) = self.session.as_mut() {
                    s.cancelled = true;
                }
            }
        }
    }

    /// Drain the probes and the running encode; start the next row when free. Call every frame.
    pub fn poll(&mut self) {
        while let Ok(p) = self.probes.1.try_recv() {
            self.apply_probe(p);
        }
        // The running row: progress, then its end.
        let mut finished = None;
        if let Some(r) = self.session.as_ref().and_then(|s| s.running.as_ref()) {
            let p = f64::from_bits(r.progress.load(Ordering::Relaxed));
            let (id, out) = (r.id, r.out.clone());
            match r.done.try_recv() {
                Ok(res) => finished = Some((id, out, res)),
                Err(std::sync::mpsc::TryRecvError::Empty) => {
                    if let Some(j) = self.job_mut(id) {
                        j.progress = p;
                    }
                }
                Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                    finished = Some((id, out, Err(glance_encode::EncodeError::Write("the encode stopped".into()))));
                }
            }
        }
        if let Some((id, out, res)) = finished {
            if let Some(s) = self.session.as_mut() {
                s.running = None;
            }
            if let Some(j) = self.job_mut(id) {
                match res {
                    Ok(o) => {
                        j.status = Status::Done;
                        j.progress = 1.0;
                        j.output_path = Some(out);
                        j.audio_warning = o.audio_warning;
                    }
                    Err(e) => {
                        // Swift's queue removes the partial output after any thrown error, whatever the encoder
                        // (`EncodeQueue.swift:1019`, `:1032`; the test-hook path `:855`, `:863`).
                        // `glance_encode::encode` already does for its own errors; this covers any `Encoder`.
                        let _ = std::fs::remove_file(&out);
                        j.status = Status::Failed;
                        j.error = Some(e.to_string());
                    }
                }
            }
        }
        self.advance();
    }

    /// Start the next session row, unless one is running or a prompt is open.
    fn advance(&mut self) {
        loop {
            let Some(s) = self.session.as_mut() else { return };
            if s.running.is_some() || s.asking.is_some() {
                return;
            }
            let Some(&id) = s.ids.get(s.next) else {
                self.session = None;
                return;
            };
            s.next += 1;
            let cancelled = s.cancelled;
            let over = s.override_;
            let Some(job) = self.job(id).cloned() else { continue };
            if job.status != Status::Queued {
                continue;
            }
            if cancelled {
                self.fail(id, "Cancelled");
                continue;
            }
            let initial = self.planned_output(&job);
            let exists = |p: &Path| p.exists();
            if job.is_rerun {
                let claimed = self.claimed(id);
                let out = naming::first_free_numbered_path(&initial, &|p: &Path| claimed.contains(&naming::standardize(p)) || p.exists());
                self.start(id, initial, out);
                return;
            }
            if !exists(&initial) {
                self.start(id, initial.clone(), initial);
                return;
            }
            let decision = match over {
                Some(SessionOverride::Overwrite) => Some(initial.clone()),
                Some(SessionOverride::AutoRename) => Some(naming::collision_free_path(&initial, &naming::RealFileSystem)),
                Some(SessionOverride::Skip) => {
                    self.fail(id, "Skipped — output exists");
                    continue;
                }
                None => match self.settings.values().collision_policy {
                    CollisionPolicy::Overwrite => Some(initial.clone()),
                    CollisionPolicy::AutoRename => Some(naming::collision_free_path(&initial, &naming::RealFileSystem)),
                    CollisionPolicy::Ask => None,
                },
            };
            match decision {
                Some(out) => {
                    self.start(id, initial, out);
                    return;
                }
                None => {
                    let suggested = naming::collision_free_path(&initial, &naming::RealFileSystem);
                    self.prompt = Some(CollisionPrompt { job: id, existing: initial.clone(), suggested_rename: suggested });
                    if let Some(s) = self.session.as_mut() {
                        s.asking = Some((id, initial));
                    }
                    return;
                }
            }
        }
    }

    /// Begin encoding a row to `out` (renamed rows remember their base name).
    fn start(&mut self, id: JobId, initial: PathBuf, out: PathBuf) {
        let writer = self.writer_version.clone();
        let Some(j) = self.job_mut(id) else { return };
        if out != initial {
            if j.pre_collision_name.is_none() {
                j.pre_collision_name = Some(j.output_name.clone());
            }
            j.output_name = out.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            j.output_name_overridden = true;
        }
        j.status = Status::Encoding;
        j.progress = 0.0;
        j.error = None;
        j.is_rerun = false;
        let mut req = request_for(j, out.clone(), writer);
        req.refined_bc4 = self.refined_bc4;
        let cancel = Arc::new(AtomicBool::new(false));
        let progress = Arc::new(AtomicU64::new(0f64.to_bits()));
        let (tx, rx) = channel();
        let (enc, c2, p2) = (self.encoder.clone(), cancel.clone(), progress.clone());
        std::thread::spawn(move || {
            let report = move |f: f64| p2.store(f.to_bits(), Ordering::Relaxed);
            let _ = tx.send(enc(&req, &report, &c2));
        });
        if let Some(s) = self.session.as_mut() {
            s.running = Some(Running { id, out, cancel, progress, done: rx });
        }
    }
}

/// The engine request for a row (`EncodeQueue.swift:873-993`): trim as a half-open range, audio on unless the
/// probe found no track, the row's codec settings.
pub fn request_for(j: &EncodeJob, out: PathBuf, writer_version: String) -> EncodeRequest {
    let frames = j.is_trimmed().then(|| {
        let (lo, hi) = j.resolved_trim(i64::MAX / 2);
        (lo.max(0) as u64)..(hi.max(0) as u64).saturating_add(1)
    });
    let s = &j.settings;
    EncodeRequest {
        source: j.source.clone(),
        output: out,
        codec: s.codec,
        container: s.container,
        video: s.video,
        output_size: s.output_size,
        resize_quality: s.resize_quality,
        aspect: s.aspect,
        crop: j.crop,
        frames,
        writer_version,
        hap_chunks: s.hap_chunks,
        alpha_type: s.alpha_type,
        audio: AudioPlan { enabled: s.audio_enabled && j.source_has_audio != Some(false), rate: s.audio_rate },
        refined_bc4: false,
    }
}

/// The real probe (`EncodeQueue.swift:383-443`): alpha, audio, the Alpha Type report, and the encode reader's
/// geometry / rate / frame count (or its refusal).
pub fn probe(id: JobId, path: &Path) -> Probe {
    let clip = glance_media::route(path).ok();
    let report = clip.as_ref().map(glance_media::alpha_report);
    let has_audio = clip.as_ref().is_some_and(|c| !c.info.audio.is_empty());
    let has_alpha = clip.as_ref().and_then(|c| match c.route {
        glance_media::Route::Dxv => None,
        _ => {
            let cc = glance_media::first_video_fourcc(path);
            if c.info.has_alpha { Some(true) } else { cc.and_then(|cc| crate::job::alpha_by_fourcc(&cc)).or(Some(false)) }
        }
    });
    let timing = glance_encode::source::open_source(path, glance_encode::frame::FrameAlpha::Straight, Default::default())
        .map(|r| {
            let i = r.info();
            (i.width, i.height, i.fps, i.total_frames)
        })
        .map_err(|e| e.to_string());
    Probe { id, has_alpha, has_audio, alpha_report: report, timing }
}

#[cfg(test)]
mod tests {
    use super::*;
    use glance_settings::MemoryStore;

    fn queue() -> Queue {
        let encoder: Encoder = Arc::new(|_, _, _| Ok(EncodeOutcome::default()));
        let prober: Prober = Arc::new(|id, _| Probe { id, has_alpha: None, has_audio: false, alpha_report: None, timing: Ok((64, 64, 30.0, 10)) });
        Queue::new(Settings::new(Box::new(MemoryStore::default())), encoder, prober, "GlEnc test".into())
    }

    #[test]
    fn overall_progress_counts_done_rows_whole_and_the_encoding_row_by_its_progress() {
        let mut q = queue();
        assert_eq!(q.overall_progress(), None);
        q.add(&[PathBuf::from("/a.mov"), PathBuf::from("/b.mov"), PathBuf::from("/c.mov"), PathBuf::from("/d.mov")]);
        q.jobs[0].status = Status::Done;
        q.jobs[1].status = Status::Encoding;
        q.jobs[1].progress = 0.5;
        q.jobs[2].status = Status::Failed;
        assert_eq!(q.overall_progress(), Some(1.5 / 4.0));
    }

    #[test]
    fn retry_requeues_a_failed_row_without_marking_a_rerun() {
        let mut q = queue();
        q.add(&[PathBuf::from("/glenc-queue-test/a.mov")]);
        let id = q.jobs[0].id;
        q.jobs[0].status = Status::Failed;
        q.jobs[0].error = Some("Cancelled".into());
        q.jobs[0].progress = 0.5;
        q.retry(id);
        let j = &q.jobs[0];
        assert_eq!((j.status, j.progress, j.error.clone(), j.is_rerun), (Status::Queued, 0.0, None, false));
        // A done row is not a Retry target.
        q.jobs[0].status = Status::Done;
        q.retry(id);
        assert_eq!(q.jobs[0].status, Status::Done);
    }

    #[test]
    fn removing_the_row_being_cropped_ends_the_crop_edit() {
        let mut q = queue();
        q.add(&[PathBuf::from("/glenc-queue-test/a.mov"), PathBuf::from("/glenc-queue-test/b.mov")]);
        let (a, b) = (q.jobs[0].id, q.jobs[1].id);
        q.begin_crop_edit(a);
        q.remove(b);
        assert!(q.crop_edit.is_some(), "another row's removal leaves the edit");
        q.remove(a);
        assert!(q.crop_edit.is_none());
    }
}
