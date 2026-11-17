//! The JSON Swift GlEnc stores in its `Data` settings (Foundation's `JSONEncoder` / `JSONDecoder` over synthesized
//! `Codable`): enums with a payload as `{"case":{"_0":value}}` (named payloads by name), payload-less cases as
//! `{"case":{}}`, `UUID` as its uppercase string, `/` written as `\/`, whole doubles without a fraction. Swift's key
//! order is a hash order that changes between runs, so values are compared, never bytes.

use glance_encode::codec::{DxvFormat, H264Profile, OutputCodec, ProResVariant, RateControl, VideoSettings};
use glance_encode::size::{OutputSize, StandardResolution};
use serde_json::{Map, Value};

/// A user-named output size (Swift's `NamedSize`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NamedSize {
    /// Swift's `UUID`, as its uppercase string.
    pub id: String,
    pub name: String,
    pub width: u32,
    pub height: u32,
}

impl NamedSize {
    pub fn label(&self) -> String {
        format!("{} — {}×{}", self.name, self.width, self.height)
    }
}

/// Swift's string escaping in `JSONEncoder` output.
fn string(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '/' => o.push_str("\\/"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            '\u{8}' => o.push_str("\\b"),
            '\u{c}' => o.push_str("\\f"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

/// A double as Swift's encoder writes it: whole values without a fraction, others shortest round-trip.
fn number(v: f64) -> String {
    if v.is_finite() && v.fract() == 0.0 && v.abs() < 1e15 { format!("{}", v as i64) } else { format!("{v}") }
}

fn case(name: &str, payload: &str) -> String {
    format!("{{{}:{payload}}}", string(name))
}

pub fn encode_codec(c: OutputCodec) -> String {
    match c {
        OutputCodec::Dxv(f) => case("dxv", &format!("{{\"_0\":{}}}", string(f.raw()))),
        OutputCodec::ProRes(v) => case("prores", &format!("{{\"_0\":{}}}", string(v.raw()))),
        OutputCodec::H264 => case("h264", "{}"),
        OutputCodec::Hevc => case("hevc", "{}"),
        OutputCodec::Mjpeg => case("mjpeg", "{}"),
    }
}

/// The one case of a Swift enum value: (name, payload object).
fn one_case(v: &Value) -> Option<(&str, &Map<String, Value>)> {
    let o = v.as_object()?;
    if o.len() != 1 {
        return None;
    }
    let (k, p) = o.iter().next()?;
    Some((k.as_str(), p.as_object()?))
}

pub fn decode_codec(bytes: &[u8]) -> Option<OutputCodec> {
    let v: Value = serde_json::from_slice(bytes).ok()?;
    let (name, p) = one_case(&v)?;
    match name {
        "dxv" => DxvFormat::from_raw(p.get("_0")?.as_str()?).map(OutputCodec::Dxv),
        "prores" => ProResVariant::from_raw(p.get("_0")?.as_str()?).map(OutputCodec::ProRes),
        "h264" => Some(OutputCodec::H264),
        "hevc" => Some(OutputCodec::Hevc),
        "mjpeg" => Some(OutputCodec::Mjpeg),
        _ => None,
    }
}

pub fn encode_video(v: &VideoSettings) -> String {
    let rc = match v.rate_control {
        RateControl::Quality(q) => case("quality", &format!("{{\"_0\":{}}}", number(q))),
        RateControl::Bitrate(b) => case("bitrate", &format!("{{\"_0\":{}}}", number(b))),
    };
    format!("{{\"rateControl\":{rc},\"keyframeIntervalFrames\":{},\"h264Profile\":{}}}", v.keyframe_interval, string(v.h264_profile.raw()))
}

/// Swift `Int` decoding: an integral JSON number only.
fn int(v: &Value) -> Option<i64> {
    v.as_i64().or_else(|| v.as_f64().filter(|f| f.fract() == 0.0 && f.abs() < 9.2e18).map(|f| f as i64))
}

pub fn decode_video(bytes: &[u8]) -> Option<VideoSettings> {
    let v: Value = serde_json::from_slice(bytes).ok()?;
    let o = v.as_object()?;
    let (name, p) = one_case(o.get("rateControl")?)?;
    let x = p.get("_0")?.as_f64()?;
    let rate_control = match name {
        "quality" => RateControl::Quality(x),
        "bitrate" => RateControl::Bitrate(x),
        _ => return None,
    };
    let k = int(o.get("keyframeIntervalFrames")?)?;
    Some(VideoSettings {
        rate_control,
        // Swift stores an Int; a negative value cannot come from the UI (it clamps to 0).
        keyframe_interval: u32::try_from(k.max(0)).unwrap_or(u32::MAX),
        h264_profile: H264Profile::from_raw(o.get("h264Profile")?.as_str()?)?,
    })
}

pub fn encode_size(s: OutputSize) -> String {
    match s {
        OutputSize::Original => case("original", "{}"),
        OutputSize::Preset(p) => case("preset", &format!("{{\"_0\":{}}}", string(p.raw()))),
        OutputSize::Custom { width, height } => case("custom", &format!("{{\"width\":{width},\"height\":{height}}}")),
    }
}

pub fn decode_size(bytes: &[u8]) -> Option<OutputSize> {
    let v: Value = serde_json::from_slice(bytes).ok()?;
    decode_size_value(&v)
}

fn decode_size_value(v: &Value) -> Option<OutputSize> {
    let (name, p) = one_case(v)?;
    match name {
        "original" => Some(OutputSize::Original),
        "preset" => StandardResolution::from_raw(p.get("_0")?.as_str()?).map(OutputSize::Preset),
        "custom" => Some(OutputSize::Custom { width: dim(p.get("width")?)?, height: dim(p.get("height")?)? }),
        _ => None,
    }
}

fn dim(v: &Value) -> Option<u32> {
    u32::try_from(int(v)?).ok()
}

pub fn encode_named_sizes(list: &[NamedSize]) -> String {
    let items: Vec<String> =
        list.iter().map(|n| format!("{{\"id\":{},\"name\":{},\"width\":{},\"height\":{}}}", string(&n.id), string(&n.name), n.width, n.height)).collect();
    format!("[{}]", items.join(","))
}

/// A Swift `UUID` string (8-4-4-4-12 hex), normalised to uppercase as Swift prints it.
pub fn uuid_string(s: &str) -> Option<String> {
    uuid::Uuid::parse_str(s).ok().filter(|_| s.len() == 36).map(|u| u.hyphenated().to_string().to_uppercase())
}

pub fn decode_named_sizes(bytes: &[u8]) -> Option<Vec<NamedSize>> {
    let v: Value = serde_json::from_slice(bytes).ok()?;
    v.as_array()?
        .iter()
        .map(|e| {
            let o = e.as_object()?;
            Some(NamedSize {
                id: uuid_string(o.get("id")?.as_str()?)?,
                name: o.get("name")?.as_str()?.to_owned(),
                width: dim(o.get("width")?)?,
                height: dim(o.get("height")?)?,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn swift_shapes_round_trip() {
        // Shapes from Swift 6.4.2's JSONEncoder (scratch probe, 2026-11-17).
        assert_eq!(decode_codec(br#"{"dxv":{"_0":"dxt1"}}"#), Some(OutputCodec::Dxv(DxvFormat::Dxt1)));
        assert_eq!(decode_codec(br#"{"prores":{"_0":"proRes422HQ"}}"#), Some(OutputCodec::ProRes(ProResVariant::ProRes422Hq)));
        assert_eq!(decode_codec(br#"{"h264":{}}"#), Some(OutputCodec::H264));
        let v = decode_video(br#"{"keyframeIntervalFrames":12,"rateControl":{"bitrate":{"_0":10}},"h264Profile":"main"}"#).unwrap();
        assert_eq!(v, VideoSettings { rate_control: RateControl::Bitrate(10.0), keyframe_interval: 12, h264_profile: H264Profile::Main });
        assert_eq!(decode_size(br#"{"original":{}}"#), Some(OutputSize::Original));
        assert_eq!(decode_size(br#"{"custom":{"height":2,"width":1}}"#), Some(OutputSize::Custom { width: 1, height: 2 }));
        assert_eq!(decode_size(br#"{"preset":{"_0":"fhd_1920_1080"}}"#), Some(OutputSize::Preset(StandardResolution::Fhd1920x1080)));
        let n =
            decode_named_sizes(r#"[{"height":4,"width":3,"name":"a\/b \"q\" é\u0001\n😀","id":"A52E4F7E-0000-4000-8000-000000000001"}]"#.as_bytes()).unwrap();
        assert_eq!(n[0].name, "a/b \"q\" é\u{1}\n😀");
        assert_eq!(encode_named_sizes(&n), r#"[{"id":"A52E4F7E-0000-4000-8000-000000000001","name":"a\/b \"q\" é\u0001\n😀","width":3,"height":4}]"#);
        for c in [OutputCodec::Dxv(DxvFormat::HapM), OutputCodec::ProRes(ProResVariant::ProRes4444), OutputCodec::Hevc, OutputCodec::Mjpeg] {
            assert_eq!(decode_codec(encode_codec(c).as_bytes()), Some(c));
        }
        let v = VideoSettings::default();
        assert_eq!(encode_video(&v), r#"{"rateControl":{"quality":{"_0":0.6}},"keyframeIntervalFrames":0,"h264Profile":"high"}"#);
        assert_eq!(decode_video(encode_video(&v).as_bytes()), Some(v));
        assert_eq!(decode_codec(b"garbage"), None);
    }
}
