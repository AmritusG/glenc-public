//! Swift GlEnc's 20 persisted settings, key for key and in its encodings (`AppSettings.swift:291-421` @ v1.6.2), over
//! glance-settings' store (on macOS the `UserDefaults` domain of the bundle id, so settings carry over at the swap
//! both ways). Missing or unreadable values read as the default, as Swift's do. "Reset to Defaults" also resets
//! the checkerboard extent (Swift leaves it: fixed on purpose, Amrit 2026-11-14 "fix").

use crate::json::{self, NamedSize};
use glance_encode::audio::AudioRate;
use glance_encode::codec::{DxvFormat, OutputCodec, OutputContainer, VideoSettings};
use glance_encode::size::{AspectMode, OutputSize, ResizeQuality};
use glance_encode::source::AlphaType;
use glance_settings::{Store, Value, read_string};

pub mod keys {
    pub const DEFAULT_QUALITY: &str = "glenc.defaultQuality";
    pub const DEFAULT_ALPHA: &str = "glenc.defaultAlpha";
    pub const DEFAULT_HAP_CHUNKS: &str = "glenc.defaultHapChunks";
    pub const DEFAULT_SOURCE_ALPHA_TYPE: &str = "glenc.defaultSourceAlphaType";
    pub const DEFAULT_RESIZE_QUALITY: &str = "glenc.defaultResizeQuality";
    pub const DEFAULT_OUTPUT_SIZE: &str = "glenc.defaultOutputSize";
    pub const DEFAULT_ASPECT_MODE: &str = "glenc.defaultAspectMode";
    pub const CUSTOM_PRESETS: &str = "glenc.customPresets";
    pub const OUTPUT_LOCATION: &str = "glenc.outputLocation";
    pub const FIXED_OUTPUT_PATH: &str = "glenc.fixedOutputPath";
    pub const TRIM_FILENAME_FORMAT: &str = "glenc.trimFilenameFormat";
    pub const PREVIEW_PANE_VISIBLE_BY_DEFAULT: &str = "glenc.previewPaneVisibleByDefault";
    pub const SHOW_CLIP_BOUNDARY: &str = "glenc.showClipBoundary";
    pub const COLLISION_POLICY: &str = "glenc.collisionPolicy";
    pub const CHECKERBOARD_SCOPE: &str = "glenc.checkerboardScope";
    pub const DEFAULT_AUDIO_ENABLED: &str = "glenc.defaultAudioEnabled";
    pub const DEFAULT_AUDIO_RATE: &str = "glenc.defaultAudioRate";
    pub const DEFAULT_OUTPUT_CODEC: &str = "glenc.defaultOutputCodec";
    pub const DEFAULT_OUTPUT_CONTAINER: &str = "glenc.defaultOutputContainer";
    pub const DEFAULT_VIDEO_SETTINGS: &str = "glenc.defaultVideoSettings";
    /// Every key, in Swift's `Keys` order.
    pub const ALL: [&str; 20] = [
        DEFAULT_QUALITY,
        DEFAULT_ALPHA,
        DEFAULT_HAP_CHUNKS,
        DEFAULT_SOURCE_ALPHA_TYPE,
        DEFAULT_RESIZE_QUALITY,
        DEFAULT_OUTPUT_SIZE,
        DEFAULT_ASPECT_MODE,
        CUSTOM_PRESETS,
        OUTPUT_LOCATION,
        FIXED_OUTPUT_PATH,
        TRIM_FILENAME_FORMAT,
        PREVIEW_PANE_VISIBLE_BY_DEFAULT,
        SHOW_CLIP_BOUNDARY,
        COLLISION_POLICY,
        CHECKERBOARD_SCOPE,
        DEFAULT_AUDIO_ENABLED,
        DEFAULT_AUDIO_RATE,
        DEFAULT_OUTPUT_CODEC,
        DEFAULT_OUTPUT_CONTAINER,
        DEFAULT_VIDEO_SETTINGS,
    ];
}

/// Swift GlEnc's bundle id: its preferences domain (the swap only, never a test).
pub const GLENC_BUNDLE_ID: &str = "com.amritus.glenc";

macro_rules! raw_enum {
    ($(#[$m:meta])* $name:ident { $($v:ident = $s:literal / $l:literal),+ $(,)? }) => {
        $(#[$m])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum $name { $($v),+ }
        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$v),+];
            pub fn raw(self) -> &'static str { match self { $($name::$v => $s),+ } }
            pub fn from_raw(s: &str) -> Option<$name> { match s { $($s => Some($name::$v),)+ _ => None } }
            pub fn label(self) -> &'static str { match self { $($name::$v => $l),+ } }
        }
    };
}

raw_enum!(
    /// The DXV / HAP family menu (Swift's `QualityTier`).
    QualityTier { Normal = "normal" / "DXV3 Normal", Hq = "hq" / "DXV3 HQ", Hap = "hap" / "HAP", HapQ = "hap_q" / "HAP Q" }
);
raw_enum!(
    /// The DXV / HAP alpha menu (Swift's `AlphaMode`).
    AlphaMode { WithoutAlpha = "no_alpha" / "No alpha", WithAlpha = "with_alpha" / "With alpha" }
);
raw_enum!(
    /// Where outputs go.
    OutputLocation { SameAsSource = "sameAsSource" / "Same folder as source", Fixed = "fixed" / "Fixed folder" }
);
raw_enum!(
    /// What happens when the output exists (Swift's `CollisionPolicy`).
    CollisionPolicy { Ask = "ask" / "Ask", Overwrite = "overwrite" / "Overwrite", AutoRename = "autoRename" / "Auto-rename" }
);
raw_enum!(
    /// How a trim shows in the auto name.
    TrimFilenameFormat { Time = "time" / "Time (MM.SS.CC)", FrameIndices = "frameIndices" / "Frame indices" }
);
raw_enum!(
    /// How far the preview's checkerboard reaches.
    CheckerboardScope { FillViewport = "fillViewport" / "Fill viewport", BehindVideoOnly = "behindVideoOnly" / "Behind video only" }
);

/// (tier, alpha) → DXV / HAP format (`UITypes.swift:70-106`).
pub fn format_of(tier: QualityTier, alpha: AlphaMode) -> DxvFormat {
    match (tier, alpha) {
        (QualityTier::Normal, AlphaMode::WithoutAlpha) => DxvFormat::Dxt1,
        (QualityTier::Normal, AlphaMode::WithAlpha) => DxvFormat::Dxt5,
        (QualityTier::Hq, AlphaMode::WithoutAlpha) => DxvFormat::Ycg6,
        (QualityTier::Hq, AlphaMode::WithAlpha) => DxvFormat::Yg10,
        (QualityTier::Hap, AlphaMode::WithoutAlpha) => DxvFormat::Hap1,
        (QualityTier::Hap, AlphaMode::WithAlpha) => DxvFormat::Hap5,
        (QualityTier::HapQ, AlphaMode::WithoutAlpha) => DxvFormat::HapY,
        (QualityTier::HapQ, AlphaMode::WithAlpha) => DxvFormat::HapM,
    }
}

pub fn tier_of(f: DxvFormat) -> QualityTier {
    match f {
        DxvFormat::Dxt1 | DxvFormat::Dxt5 => QualityTier::Normal,
        DxvFormat::Ycg6 | DxvFormat::Yg10 => QualityTier::Hq,
        DxvFormat::Hap1 | DxvFormat::Hap5 | DxvFormat::HapA => QualityTier::Hap,
        DxvFormat::HapY | DxvFormat::HapM => QualityTier::HapQ,
    }
}

pub fn alpha_of(f: DxvFormat) -> AlphaMode {
    if f.has_alpha() { AlphaMode::WithAlpha } else { AlphaMode::WithoutAlpha }
}

/// Swift's `object(forKey:) as? Int`: an integer number (a whole real converts; a boolean bridges to 0 / 1).
fn object_int(v: Option<Value>) -> Option<i64> {
    match v? {
        Value::Int(i) => Some(i),
        Value::Real(r) if r.fract() == 0.0 && r.abs() < 9.2e18 => Some(r as i64),
        Value::Bool(b) => Some(i64::from(b)),
        _ => None,
    }
}

/// Swift's `object(forKey:) as? Bool`: a boolean, or the number 0 / 1.
fn object_bool(v: Option<Value>) -> Option<bool> {
    match v? {
        Value::Bool(b) => Some(b),
        Value::Int(0) => Some(false),
        Value::Int(1) => Some(true),
        Value::Real(r) if r == 0.0 || r == 1.0 => Some(r == 1.0),
        _ => None,
    }
}

/// Swift's `integer(forKey:)`: a number (reals truncate), a boolean, or a string that parses; else 0.
fn integer(v: Option<Value>) -> i64 {
    match v {
        Some(Value::Int(i)) => i,
        Some(Value::Real(r)) if r.is_finite() => r as i64,
        Some(Value::Bool(b)) => i64::from(b),
        Some(Value::String(s)) => s.trim().parse::<i64>().ok().or_else(|| s.trim().parse::<f64>().ok().map(|f| f as i64)).unwrap_or(0),
        _ => 0,
    }
}

fn data(store: &dyn Store, key: &str) -> Option<Vec<u8>> {
    match store.get(key) {
        Some(Value::Data(d)) => Some(d),
        _ => None,
    }
}

/// The 20 values as one snapshot.
#[derive(Clone, Debug, PartialEq)]
pub struct Values {
    pub default_quality: QualityTier,
    pub default_alpha: AlphaMode,
    pub default_hap_chunks: u32,
    pub default_source_alpha_type: AlphaType,
    pub default_output_codec: OutputCodec,
    pub default_output_container: OutputContainer,
    pub default_video_settings: VideoSettings,
    pub default_resize_quality: ResizeQuality,
    pub default_output_size: OutputSize,
    pub default_aspect_mode: AspectMode,
    pub custom_presets: Vec<NamedSize>,
    pub output_location: OutputLocation,
    pub fixed_output_path: String,
    pub trim_filename_format: TrimFilenameFormat,
    pub collision_policy: CollisionPolicy,
    pub preview_pane_visible_by_default: bool,
    pub show_clip_boundary: bool,
    pub checkerboard_scope: CheckerboardScope,
    pub default_audio_enabled: bool,
    pub default_audio_rate: AudioRate,
}

impl Default for Values {
    /// Swift's factory values (`AppSettings.init` defaults; `resetToDefaults`).
    fn default() -> Values {
        Values {
            default_quality: QualityTier::Normal,
            default_alpha: AlphaMode::WithoutAlpha,
            default_hap_chunks: 1,
            default_source_alpha_type: AlphaType::Premultiplied,
            default_output_codec: OutputCodec::Dxv(DxvFormat::Dxt1),
            default_output_container: OutputContainer::Mov,
            default_video_settings: VideoSettings::default(),
            default_resize_quality: ResizeQuality::Auto,
            default_output_size: OutputSize::Original,
            default_aspect_mode: AspectMode::Letterbox,
            custom_presets: Vec::new(),
            output_location: OutputLocation::SameAsSource,
            fixed_output_path: String::new(),
            trim_filename_format: TrimFilenameFormat::Time,
            collision_policy: CollisionPolicy::Ask,
            preview_pane_visible_by_default: true,
            show_clip_boundary: true,
            checkerboard_scope: CheckerboardScope::FillViewport,
            default_audio_enabled: true,
            default_audio_rate: AudioRate::Original,
        }
    }
}

impl Values {
    /// Read every key the way `AppSettings.init` does.
    pub fn load(store: &dyn Store) -> Values {
        let s = |k: &str| read_string(store, k).unwrap_or_default();
        let d = Values::default();
        Values {
            default_quality: QualityTier::from_raw(&s(keys::DEFAULT_QUALITY)).unwrap_or(d.default_quality),
            default_alpha: AlphaMode::from_raw(&s(keys::DEFAULT_ALPHA)).unwrap_or(d.default_alpha),
            default_hap_chunks: object_int(store.get(keys::DEFAULT_HAP_CHUNKS)).unwrap_or(1).clamp(1, 64) as u32,
            default_source_alpha_type: AlphaType::from_raw(&s(keys::DEFAULT_SOURCE_ALPHA_TYPE)).unwrap_or_default(),
            default_output_codec: data(store, keys::DEFAULT_OUTPUT_CODEC).and_then(|b| json::decode_codec(&b)).unwrap_or(d.default_output_codec),
            default_output_container: OutputContainer::from_raw(&s(keys::DEFAULT_OUTPUT_CONTAINER)).unwrap_or(OutputContainer::Mov),
            default_video_settings: data(store, keys::DEFAULT_VIDEO_SETTINGS).and_then(|b| json::decode_video(&b)).unwrap_or_default(),
            default_resize_quality: ResizeQuality::from_raw(&s(keys::DEFAULT_RESIZE_QUALITY)).unwrap_or(ResizeQuality::Auto),
            default_output_size: data(store, keys::DEFAULT_OUTPUT_SIZE).and_then(|b| json::decode_size(&b)).unwrap_or(OutputSize::Original),
            default_aspect_mode: AspectMode::from_raw(&s(keys::DEFAULT_ASPECT_MODE)).unwrap_or(AspectMode::Letterbox),
            custom_presets: data(store, keys::CUSTOM_PRESETS).and_then(|b| json::decode_named_sizes(&b)).unwrap_or_default(),
            output_location: OutputLocation::from_raw(&s(keys::OUTPUT_LOCATION)).unwrap_or(d.output_location),
            fixed_output_path: read_string(store, keys::FIXED_OUTPUT_PATH).unwrap_or_default(),
            trim_filename_format: TrimFilenameFormat::from_raw(&s(keys::TRIM_FILENAME_FORMAT)).unwrap_or(d.trim_filename_format),
            collision_policy: CollisionPolicy::from_raw(&s(keys::COLLISION_POLICY)).unwrap_or(d.collision_policy),
            preview_pane_visible_by_default: object_bool(store.get(keys::PREVIEW_PANE_VISIBLE_BY_DEFAULT)).unwrap_or(true),
            show_clip_boundary: object_bool(store.get(keys::SHOW_CLIP_BOUNDARY)).unwrap_or(true),
            checkerboard_scope: CheckerboardScope::from_raw(&s(keys::CHECKERBOARD_SCOPE)).unwrap_or(d.checkerboard_scope),
            default_audio_enabled: object_bool(store.get(keys::DEFAULT_AUDIO_ENABLED)).unwrap_or(true),
            default_audio_rate: AudioRate::from_persist_int(integer(store.get(keys::DEFAULT_AUDIO_RATE))),
        }
    }
}

/// One setting changed (each is written at once, as Swift's `didSet` does).
#[derive(Clone, Debug, PartialEq)]
pub enum Change {
    DefaultQuality(QualityTier),
    DefaultAlpha(AlphaMode),
    DefaultHapChunks(u32),
    DefaultSourceAlphaType(AlphaType),
    DefaultOutputCodec(OutputCodec),
    DefaultOutputContainer(OutputContainer),
    DefaultVideoSettings(VideoSettings),
    DefaultResizeQuality(ResizeQuality),
    DefaultOutputSize(OutputSize),
    DefaultAspectMode(AspectMode),
    CustomPresets(Vec<NamedSize>),
    OutputLocation(OutputLocation),
    FixedOutputPath(String),
    TrimFilenameFormat(TrimFilenameFormat),
    CollisionPolicy(CollisionPolicy),
    PreviewPaneVisibleByDefault(bool),
    ShowClipBoundary(bool),
    CheckerboardScope(CheckerboardScope),
    DefaultAudioEnabled(bool),
    DefaultAudioRate(AudioRate),
}

/// The settings over a store: the values in memory, every change written through.
pub struct Settings {
    store: Box<dyn Store>,
    values: Values,
}

impl Settings {
    pub fn new(store: Box<dyn Store>) -> Settings {
        let values = Values::load(&*store);
        Settings { store, values }
    }
    pub fn store(&self) -> &dyn Store {
        &*self.store
    }
    pub fn values(&self) -> &Values {
        &self.values
    }

    /// Apply and persist one change, in Swift's encoding.
    pub fn set(&mut self, c: Change) {
        let st = &*self.store;
        let v = &mut self.values;
        let s = |k: &str, x: &str| st.set(k, Value::String(x.to_owned()));
        let b = |k: &str, x: Vec<u8>| st.set(k, Value::Data(x));
        match c {
            Change::DefaultQuality(x) => {
                v.default_quality = x;
                s(keys::DEFAULT_QUALITY, x.raw());
            }
            Change::DefaultAlpha(x) => {
                v.default_alpha = x;
                s(keys::DEFAULT_ALPHA, x.raw());
            }
            Change::DefaultHapChunks(x) => {
                v.default_hap_chunks = x;
                st.set(keys::DEFAULT_HAP_CHUNKS, Value::Int(i64::from(x)));
            }
            Change::DefaultSourceAlphaType(x) => {
                v.default_source_alpha_type = x;
                s(keys::DEFAULT_SOURCE_ALPHA_TYPE, x.raw());
            }
            Change::DefaultOutputCodec(x) => {
                v.default_output_codec = x;
                b(keys::DEFAULT_OUTPUT_CODEC, json::encode_codec(x).into_bytes());
            }
            Change::DefaultOutputContainer(x) => {
                v.default_output_container = x;
                s(keys::DEFAULT_OUTPUT_CONTAINER, x.raw());
            }
            Change::DefaultVideoSettings(x) => {
                v.default_video_settings = x;
                b(keys::DEFAULT_VIDEO_SETTINGS, json::encode_video(&x).into_bytes());
            }
            Change::DefaultResizeQuality(x) => {
                v.default_resize_quality = x;
                s(keys::DEFAULT_RESIZE_QUALITY, x.raw());
            }
            Change::DefaultOutputSize(x) => {
                v.default_output_size = x;
                b(keys::DEFAULT_OUTPUT_SIZE, json::encode_size(x).into_bytes());
            }
            Change::DefaultAspectMode(x) => {
                v.default_aspect_mode = x;
                s(keys::DEFAULT_ASPECT_MODE, x.raw());
            }
            Change::CustomPresets(x) => {
                b(keys::CUSTOM_PRESETS, json::encode_named_sizes(&x).into_bytes());
                v.custom_presets = x;
            }
            Change::OutputLocation(x) => {
                v.output_location = x;
                s(keys::OUTPUT_LOCATION, x.raw());
            }
            Change::FixedOutputPath(x) => {
                s(keys::FIXED_OUTPUT_PATH, &x);
                v.fixed_output_path = x;
            }
            Change::TrimFilenameFormat(x) => {
                v.trim_filename_format = x;
                s(keys::TRIM_FILENAME_FORMAT, x.raw());
            }
            Change::CollisionPolicy(x) => {
                v.collision_policy = x;
                s(keys::COLLISION_POLICY, x.raw());
            }
            Change::PreviewPaneVisibleByDefault(x) => {
                v.preview_pane_visible_by_default = x;
                st.set(keys::PREVIEW_PANE_VISIBLE_BY_DEFAULT, Value::Bool(x));
            }
            Change::ShowClipBoundary(x) => {
                v.show_clip_boundary = x;
                st.set(keys::SHOW_CLIP_BOUNDARY, Value::Bool(x));
            }
            Change::CheckerboardScope(x) => {
                v.checkerboard_scope = x;
                s(keys::CHECKERBOARD_SCOPE, x.raw());
            }
            Change::DefaultAudioEnabled(x) => {
                v.default_audio_enabled = x;
                st.set(keys::DEFAULT_AUDIO_ENABLED, Value::Bool(x));
            }
            Change::DefaultAudioRate(x) => {
                v.default_audio_rate = x;
                st.set(keys::DEFAULT_AUDIO_RATE, Value::Int(x.persist_int()));
            }
        }
    }

    /// Swift's `addCustomPreset`: names are trimmed; a name already present (case-insensitive, trimmed) is
    /// replaced in place, keeping its id; an empty name is ignored.
    pub fn add_custom_preset(&mut self, p: NamedSize) {
        let name = p.name.trim().to_owned();
        if name.is_empty() {
            return;
        }
        let needle = name.to_lowercase();
        let mut list = self.values.custom_presets.clone();
        if let Some(e) = list.iter_mut().find(|e| e.name.trim().to_lowercase() == needle) {
            *e = NamedSize { id: e.id.clone(), name, width: p.width, height: p.height };
        } else {
            list.push(NamedSize { id: p.id, name, width: p.width, height: p.height });
        }
        self.set(Change::CustomPresets(list));
    }

    pub fn remove_custom_preset(&mut self, id: &str) {
        let list = self.values.custom_presets.iter().filter(|e| e.id != id).cloned().collect();
        self.set(Change::CustomPresets(list));
    }

    /// "Reset to Defaults": every value, the checkerboard extent included (the "fix").
    pub fn reset_to_defaults(&mut self) {
        let d = Values::default();
        for c in [
            Change::DefaultQuality(d.default_quality),
            Change::DefaultAlpha(d.default_alpha),
            Change::DefaultHapChunks(d.default_hap_chunks),
            Change::DefaultSourceAlphaType(d.default_source_alpha_type),
            Change::DefaultOutputCodec(d.default_output_codec),
            Change::DefaultOutputContainer(d.default_output_container),
            Change::DefaultVideoSettings(d.default_video_settings),
            Change::DefaultResizeQuality(d.default_resize_quality),
            Change::DefaultOutputSize(d.default_output_size),
            Change::DefaultAspectMode(d.default_aspect_mode),
            Change::CustomPresets(Vec::new()),
            Change::OutputLocation(d.output_location),
            Change::FixedOutputPath(String::new()),
            Change::TrimFilenameFormat(d.trim_filename_format),
            Change::PreviewPaneVisibleByDefault(true),
            Change::ShowClipBoundary(true),
            Change::CollisionPolicy(d.collision_policy),
            Change::DefaultAudioEnabled(true),
            Change::DefaultAudioRate(AudioRate::Original),
            Change::CheckerboardScope(d.checkerboard_scope),
        ] {
            self.set(c);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use glance_settings::MemoryStore;

    #[test]
    fn empty_store_reads_swifts_defaults() {
        assert_eq!(Values::load(&MemoryStore::default()), Values::default());
    }

    #[test]
    fn amrits_shapes_read() {
        // The shapes in Amrit's real domain (read-only `defaults export`, 2026-11-17).
        let st = MemoryStore::default();
        st.set(keys::CHECKERBOARD_SCOPE, Value::String("behindVideoOnly".into()));
        st.set(keys::DEFAULT_OUTPUT_SIZE, Value::Data(br#"{"original":{}}"#.to_vec()));
        st.set(keys::PREVIEW_PANE_VISIBLE_BY_DEFAULT, Value::Bool(true));
        st.set(keys::DEFAULT_HAP_CHUNKS, Value::Int(200));
        st.set(keys::DEFAULT_AUDIO_RATE, Value::Int(96_000));
        let v = Values::load(&st);
        assert_eq!(v.checkerboard_scope, CheckerboardScope::BehindVideoOnly);
        assert_eq!(v.default_hap_chunks, 64);
        assert_eq!(v.default_audio_rate, AudioRate::Hz96000);
    }

    #[test]
    fn every_change_round_trips_and_reset_includes_the_checkerboard() {
        let mut s = Settings::new(Box::new(MemoryStore::default()));
        s.set(Change::CheckerboardScope(CheckerboardScope::BehindVideoOnly));
        s.set(Change::DefaultOutputCodec(OutputCodec::Hevc));
        s.add_custom_preset(NamedSize { id: "A52E4F7E-0000-4000-8000-000000000001".into(), name: "  Wall ".into(), width: 10, height: 20 });
        s.add_custom_preset(NamedSize { id: "B52E4F7E-0000-4000-8000-000000000002".into(), name: "wall".into(), width: 30, height: 40 });
        assert_eq!(s.values().custom_presets.len(), 1);
        assert_eq!(s.values().custom_presets[0].id, "A52E4F7E-0000-4000-8000-000000000001");
        assert_eq!(Values::load(s.store()), *s.values());
        s.reset_to_defaults();
        assert_eq!(*s.values(), Values::default());
        assert_eq!(Values::load(s.store()), Values::default());
    }
}
