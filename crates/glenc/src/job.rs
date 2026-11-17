//! One queue row (Swift GlEnc 1.6.2 `EncodeJob.swift`) and the codec settings a batch edit can change
//! (`JobSettings.swift`), with Swift's rules for every menu: tier × alpha → format, ProRes steered by the source's
//! alpha, H.264 / HEVC default to `.mp4`, audio rates above a container's cap fall back to 48 kHz, chunks 1…64.

use crate::settings::{AlphaMode, QualityTier, alpha_of, format_of, tier_of};
use glance_encode::audio::AudioRate;
use glance_encode::codec::{DxvFormat, H264Profile, OutputCodec, OutputContainer, ProResVariant, RateControl, VideoSettings};
use glance_encode::frame::CropRect;
use glance_encode::size::{AspectMode, OutputSize, ResizeQuality};
use glance_encode::source::AlphaType;
use glance_media::AlphaReport;
use std::path::{Path, PathBuf};

/// A row's state (Swift's `EncodeJob.Status`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Status {
    Queued,
    Encoding,
    Done,
    Failed,
}

impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Status::Queued => "Queued",
            Status::Encoding => "Encoding",
            Status::Done => "Done",
            Status::Failed => "Failed",
        }
    }
}

/// Which file the preview shows.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum PreviewSide {
    #[default]
    Source,
    Output,
}

/// The settings a batch edit touches (Swift's `JobSettings`).
#[derive(Clone, Debug, PartialEq)]
pub struct JobSettings {
    pub format: DxvFormat,
    pub codec: OutputCodec,
    pub container: OutputContainer,
    pub video: VideoSettings,
    pub hap_chunks: u32,
    pub audio_enabled: bool,
    pub audio_rate: AudioRate,
    pub output_size: OutputSize,
    pub resize_quality: ResizeQuality,
    pub aspect: AspectMode,
    pub alpha_type: AlphaType,
}

impl Default for JobSettings {
    fn default() -> JobSettings {
        JobSettings {
            format: DxvFormat::Dxt1,
            codec: OutputCodec::Dxv(DxvFormat::Dxt1),
            container: OutputContainer::Mov,
            video: VideoSettings::default(),
            hap_chunks: 1,
            audio_enabled: true,
            audio_rate: AudioRate::Original,
            output_size: OutputSize::Original,
            resize_quality: ResizeQuality::Auto,
            aspect: AspectMode::Letterbox,
            alpha_type: AlphaType::Premultiplied,
        }
    }
}

/// The family menu of a row ("DXV3 Normal", "DXV3 HQ", "HAP", "HAP Q", "ProRes", "H.264", "HEVC", "Motion JPEG").
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Family {
    Tier(QualityTier),
    ProRes,
    H264,
    Hevc,
    Mjpeg,
}

impl Family {
    pub const ALL: [Family; 8] = [
        Family::Tier(QualityTier::Normal),
        Family::Tier(QualityTier::Hq),
        Family::Tier(QualityTier::Hap),
        Family::Tier(QualityTier::HapQ),
        Family::ProRes,
        Family::H264,
        Family::Hevc,
        Family::Mjpeg,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Family::Tier(t) => t.label(),
            Family::ProRes => "ProRes",
            Family::H264 => "H.264",
            Family::Hevc => "HEVC",
            Family::Mjpeg => "Motion JPEG",
        }
    }
}

impl JobSettings {
    pub fn is_dxv_family(&self) -> bool {
        matches!(self.codec, OutputCodec::Dxv(_))
    }
    pub fn is_hap(&self) -> bool {
        self.is_dxv_family() && self.format.is_hap()
    }
    pub fn is_prores(&self) -> bool {
        matches!(self.codec, OutputCodec::ProRes(_))
    }
    pub fn is_h264_or_hevc(&self) -> bool {
        matches!(self.codec, OutputCodec::H264 | OutputCodec::Hevc)
    }
    pub fn family(&self) -> Family {
        match self.codec {
            OutputCodec::Dxv(_) => Family::Tier(tier_of(self.format)),
            OutputCodec::ProRes(_) => Family::ProRes,
            OutputCodec::H264 => Family::H264,
            OutputCodec::Hevc => Family::Hevc,
            OutputCodec::Mjpeg => Family::Mjpeg,
        }
    }
    /// Choose a family from the first menu (`JobCardView` / `SettingsMenuItems`).
    pub fn select_family(&mut self, f: Family, source_has_alpha: Option<bool>) {
        match f {
            Family::Tier(t) => self.select_dxv_tier(t),
            Family::ProRes => self.select_prores(source_has_alpha),
            Family::H264 => self.select_video_codec(OutputCodec::H264),
            Family::Hevc => self.select_video_codec(OutputCodec::Hevc),
            Family::Mjpeg => self.select_video_codec(OutputCodec::Mjpeg),
        }
    }
    pub fn select_dxv_tier(&mut self, tier: QualityTier) {
        self.format = format_of(tier, alpha_of(self.format));
        self.codec = OutputCodec::Dxv(self.format);
        self.container = OutputContainer::Mov;
    }
    /// ProRes: 4444 for an alpha source, else 422 (unknown alpha → the current format's).
    pub fn select_prores(&mut self, source_has_alpha: Option<bool>) {
        let alpha = source_has_alpha.unwrap_or(self.format.has_alpha());
        self.codec = OutputCodec::ProRes(if alpha { ProResVariant::ProRes4444 } else { ProResVariant::ProRes422 });
        self.container = OutputContainer::Mov;
    }
    pub fn select_video_codec(&mut self, codec: OutputCodec) {
        self.codec = codec;
        self.container = if codec.allowed_containers().contains(&OutputContainer::Mp4) { OutputContainer::Mp4 } else { OutputContainer::Mov };
        self.clamp_audio_rate();
    }
    pub fn set_alpha(&mut self, a: AlphaMode) {
        if !self.is_dxv_family() {
            return;
        }
        self.format = format_of(tier_of(self.format), a);
        self.codec = OutputCodec::Dxv(self.format);
    }
    pub fn set_prores_variant(&mut self, v: ProResVariant) {
        if self.is_prores() {
            self.codec = OutputCodec::ProRes(v);
        }
    }
    pub fn set_container(&mut self, c: OutputContainer) {
        if self.codec.allowed_containers().contains(&c) {
            self.container = c;
            self.clamp_audio_rate();
        }
    }
    pub fn set_rate_control_mode(&mut self, quality: bool) {
        if !self.is_h264_or_hevc() || quality == matches!(self.video.rate_control, RateControl::Quality(_)) {
            return;
        }
        self.video.rate_control = if quality { RateControl::Quality(0.6) } else { RateControl::Bitrate(10.0) };
    }
    pub fn set_quality(&mut self, q: f64) {
        if self.is_h264_or_hevc() {
            self.video.rate_control = RateControl::Quality(q.clamp(0.1, 1.0));
        }
    }
    pub fn set_bitrate_mbps(&mut self, m: f64) {
        if self.is_h264_or_hevc() {
            self.video.rate_control = RateControl::Bitrate(m.max(0.1));
        }
    }
    pub fn set_keyframe_interval(&mut self, frames: i64) {
        if self.is_h264_or_hevc() {
            self.video.keyframe_interval = u32::try_from(frames.max(0)).unwrap_or(u32::MAX);
        }
    }
    pub fn set_h264_profile(&mut self, p: H264Profile) {
        if self.codec == OutputCodec::H264 {
            self.video.h264_profile = p;
        }
    }
    pub fn set_hap_chunks(&mut self, n: i64) {
        if self.is_hap() {
            self.hap_chunks = n.clamp(1, 64) as u32;
        }
    }
    pub fn set_audio_rate(&mut self, r: AudioRate) {
        self.audio_rate = r;
        self.clamp_audio_rate();
    }
    pub fn clamp_audio_rate(&mut self) {
        if self.audio_rate.hz().is_some_and(|hz| hz > self.container.max_audio_rate()) {
            self.audio_rate = AudioRate::Hz48000;
        }
    }
    /// A rate the container cannot carry (shown disabled: "MPEG-4 (AAC) caps at 48 kHz").
    pub fn audio_rate_unavailable(&self, r: AudioRate) -> bool {
        r.hz().is_some_and(|hz| hz > self.container.max_audio_rate())
    }
    /// The settings that feed the auto name changed.
    pub fn affects_auto_name(&self, other: &JobSettings) -> bool {
        self.format != other.format || self.codec != other.codec || self.container != other.container
    }
}

/// A unique row id.
pub type JobId = u64;

/// One row (Swift's `EncodeJob`).
#[derive(Clone, Debug)]
pub struct EncodeJob {
    pub id: JobId,
    pub source: PathBuf,
    pub settings: JobSettings,
    pub source_has_audio: Option<bool>,
    pub source_has_alpha: Option<bool>,
    pub alpha_report: Option<AlphaReport>,
    pub status: Status,
    pub progress: f64,
    pub output_path: Option<PathBuf>,
    pub error: Option<String>,
    pub audio_warning: Option<String>,
    pub preview_side: PreviewSide,
    pub in_frame: Option<i64>,
    pub out_frame: Option<i64>,
    pub output_name: String,
    pub output_name_overridden: bool,
    pub source_fps: Option<f64>,
    pub source_frame_count: Option<u64>,
    pub source_width: Option<u32>,
    pub source_height: Option<u32>,
    pub crop: Option<CropRect>,
    pub is_rerun: bool,
    pub pre_collision_name: Option<String>,
}

impl EncodeJob {
    pub fn new(id: JobId, source: PathBuf, settings: JobSettings) -> EncodeJob {
        EncodeJob {
            id,
            source,
            settings,
            source_has_audio: None,
            source_has_alpha: None,
            alpha_report: None,
            status: Status::Queued,
            progress: 0.0,
            output_path: None,
            error: None,
            audio_warning: None,
            preview_side: PreviewSide::Source,
            in_frame: None,
            out_frame: None,
            output_name: String::new(),
            output_name_overridden: false,
            source_fps: None,
            source_frame_count: None,
            source_width: None,
            source_height: None,
            crop: None,
            is_rerun: false,
            pre_collision_name: None,
        }
    }
    pub fn is_trimmed(&self) -> bool {
        self.in_frame.is_some() || self.out_frame.is_some()
    }
    /// Swift's `resolvedTrimRange`: both ends inclusive, clamped to the clip, swapped when reversed.
    pub fn resolved_trim(&self, total: i64) -> (i64, i64) {
        if total <= 0 {
            return (0, 0);
        }
        let last = total - 1;
        let lo = self.in_frame.unwrap_or(0).min(last).max(0);
        let hi = self.out_frame.unwrap_or(last).min(last).max(0);
        (lo.min(hi), lo.max(hi))
    }
    /// The size actually read: the crop size when cropped, else the source size.
    pub fn effective_source_size(&self) -> Option<(u32, u32)> {
        if let Some(c) = self.crop.filter(|c| c.width > 0 && c.height > 0) {
            return Some((c.width, c.height));
        }
        Some((self.source_width?, self.source_height?))
    }
    pub fn is_finished(&self) -> bool {
        matches!(self.status, Status::Done | Status::Failed)
    }
    /// Encoding and done rows are locked against edits.
    pub fn is_mutable(&self) -> bool {
        matches!(self.status, Status::Queued | Status::Failed)
    }
    /// The output next to the source.
    pub fn default_output_path(&self) -> PathBuf {
        self.source.parent().unwrap_or(Path::new("")).join(&self.output_name)
    }
    /// The 422 family drops a source's alpha ("alpha will be flattened").
    pub fn alpha_will_be_flattened(&self) -> bool {
        match self.settings.codec {
            OutputCodec::ProRes(v) if !v.has_alpha() => self.source_has_alpha.unwrap_or(self.settings.format.has_alpha()),
            _ => false,
        }
    }
}

/// Swift's `probeSourceAlpha` fallback by FourCC, when the format description does not state alpha
/// (`EncodeJob.swift:443-455`).
pub fn alpha_by_fourcc(cc: &[u8; 4]) -> Option<bool> {
    match cc {
        b"ap4h" | b"ap4x" | b"Hap5" | b"HapM" | b"HapA" => Some(true),
        b"apcn" | b"apch" | b"apcs" | b"apco" | b"HapY" | b"Hap1" => Some(false),
        _ => None,
    }
}
