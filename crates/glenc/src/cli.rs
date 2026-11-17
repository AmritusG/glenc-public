//! `glenc-cli`: one input, one output, one call into the encode engine (Swift GlEnc 1.6.2
//! `Sources/glenc-cli/GlencCLI.swift`). Swift's options, defaults, words and exit codes: a usage error prints
//! `Error: …` and the usage to stderr and exits 64 (swift-argument-parser's `EX_USAGE`); a failed encode prints
//! `error: encode failed: …`, removes the partial file and exits 1; success prints the output path on stdout.
//! The version string stays `glenc-cli 1.0.0`, as Swift's (independent of the app's).

use glance_encode::audio::{AudioPlan, AudioRate};
use glance_encode::codec::{DxvFormat, OutputCodec, OutputContainer, ProResVariant, VideoSettings};
use glance_encode::frame::CropRect;
use glance_encode::size::{AspectMode, OutputSize, ResizeQuality};
use glance_encode::source::AlphaType;
use glance_encode::{EncodeRequest, encode};
use std::ops::Range;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;

pub const VERSION: &str = "glenc-cli 1.0.0";
pub const HELP: &str = include_str!("cli_help.txt");
const USAGE: &str = "Usage: glenc-cli [<options>] <input> <output>\n  See 'glenc-cli --help' for more information.\n";

/// What a run printed and its exit code.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
}

fn usage_error(msg: &str) -> Outcome {
    Outcome { stdout: String::new(), stderr: format!("Error: {msg}\n{USAGE}"), code: 64 }
}

/// Swift's `\(codec)`: `dxv(GlEncCore.DXVFormat.dxt1)`, `prores(GlEncCore.ProResVariant.proRes422)`, `h264`.
pub fn swift_codec_description(c: OutputCodec) -> String {
    match c {
        OutputCodec::Dxv(f) => format!("dxv(GlEncCore.DXVFormat.{})", swift_case(f)),
        OutputCodec::ProRes(v) => format!("prores(GlEncCore.ProResVariant.{})", v.raw()),
        OutputCodec::H264 => "h264".into(),
        OutputCodec::Hevc => "hevc".into(),
        OutputCodec::Mjpeg => "mjpeg".into(),
    }
}

/// The Swift case name (not the raw value): `hapY` for `hapy`.
fn swift_case(f: DxvFormat) -> &'static str {
    match f {
        DxvFormat::HapY => "hapY",
        DxvFormat::HapA => "hapA",
        DxvFormat::HapM => "hapM",
        f => f.raw(),
    }
}

pub fn parse_codec(s: &str) -> Result<OutputCodec, String> {
    let key = s.to_lowercase();
    if let Some(f) = DxvFormat::from_raw(&key) {
        return Ok(OutputCodec::Dxv(f));
    }
    Ok(match key.as_str() {
        "prores422" => OutputCodec::ProRes(ProResVariant::ProRes422),
        "prores422hq" => OutputCodec::ProRes(ProResVariant::ProRes422Hq),
        "prores422lt" => OutputCodec::ProRes(ProResVariant::ProRes422Lt),
        "prores422proxy" => OutputCodec::ProRes(ProResVariant::ProRes422Proxy),
        "prores4444" => OutputCodec::ProRes(ProResVariant::ProRes4444),
        "h264" => OutputCodec::H264,
        "hevc" => OutputCodec::Hevc,
        "mjpeg" => OutputCodec::Mjpeg,
        _ => {
            return Err(format!(
                "unknown --codec: {s}\nvalid: dxt1 dxt5 ycg6 yg10 hap1 hap5 hapy hapa hapm prores422 prores422hq prores422lt prores422proxy prores4444 h264 hevc mjpeg"
            ));
        }
    })
}

/// Swift's `Int(String)`: an optional sign and decimal digits, nothing else.
fn swift_int(s: &str) -> Option<i64> {
    let digits = s.strip_prefix(['+', '-']).unwrap_or(s);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

/// Swift's `split(separator: ":")` drops empty pieces.
fn pieces(s: &str) -> Vec<&str> {
    s.split(':').filter(|p| !p.is_empty()).collect()
}

/// The parsed command line.
#[derive(Clone, Debug, PartialEq)]
pub struct Args {
    pub input: String,
    pub output: String,
    pub codec: String,
    pub container: String,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub resize_quality: String,
    pub aspect: String,
    pub crop: Option<String>,
    pub trim: Option<String>,
    pub audio: bool,
    pub chunks: i64,
    pub alpha_type: String,
    pub writer_version: String,
    pub verbose: bool,
}

enum Parsed {
    Run(Box<Args>),
    Print(Outcome),
}

const OPTIONS: [&str; 10] = ["--codec", "--container", "--width", "--height", "--resize-quality", "--aspect", "--crop", "--trim", "--chunks", "--alpha-type"];

fn parse(argv: &[String]) -> Parsed {
    let mut a = Args {
        input: String::new(),
        output: String::new(),
        codec: "dxt1".into(),
        container: "mov".into(),
        width: None,
        height: None,
        resize_quality: "auto".into(),
        aspect: "letterbox".into(),
        crop: None,
        trim: None,
        audio: true,
        chunks: 1,
        alpha_type: AlphaType::Premultiplied.raw().into(),
        writer_version: VERSION.into(),
        verbose: false,
    };
    let mut positional = Vec::new();
    let mut i = 0;
    while i < argv.len() {
        let arg = &argv[i];
        i += 1;
        match arg.as_str() {
            "-h" | "--help" => return Parsed::Print(Outcome { stdout: HELP.into(), stderr: String::new(), code: 0 }),
            "--version" => return Parsed::Print(Outcome { stdout: format!("{VERSION}\n"), stderr: String::new(), code: 0 }),
            "--audio" => a.audio = true,
            "--no-audio" => a.audio = false,
            "--verbose" => a.verbose = true,
            "--" => {
                positional.extend(argv[i..].iter().cloned());
                break;
            }
            _ if arg.starts_with('-') && arg.len() > 1 => {
                let (name, inline) = match arg.split_once('=') {
                    Some((n, v)) => (n.to_owned(), Some(v.to_owned())),
                    None => (arg.clone(), None),
                };
                let name = if name == "-c" { "--codec".to_owned() } else { name };
                if !OPTIONS.contains(&name.as_str()) && name != "--writer-version" {
                    return Parsed::Print(usage_error(&format!("Unknown option '{arg}'")));
                }
                let value = match inline {
                    Some(v) => v,
                    None if i < argv.len() => {
                        i += 1;
                        argv[i - 1].clone()
                    }
                    None => return Parsed::Print(usage_error(&format!("Missing value for '{name} <{}>'", &name[2..]))),
                };
                let int = |v: &str| swift_int(v).ok_or_else(|| usage_error(&format!("The value '{v}' is invalid for '{name} <{}>'", &name[2..])));
                match name.as_str() {
                    "--codec" => a.codec = value,
                    "--container" => a.container = value,
                    "--width" => match int(&value) {
                        Ok(v) => a.width = Some(v),
                        Err(o) => return Parsed::Print(o),
                    },
                    "--height" => match int(&value) {
                        Ok(v) => a.height = Some(v),
                        Err(o) => return Parsed::Print(o),
                    },
                    "--resize-quality" => a.resize_quality = value,
                    "--aspect" => a.aspect = value,
                    "--crop" => a.crop = Some(value),
                    "--trim" => a.trim = Some(value),
                    "--chunks" => match int(&value) {
                        Ok(v) => a.chunks = v,
                        Err(o) => return Parsed::Print(o),
                    },
                    "--alpha-type" => a.alpha_type = value,
                    _ => a.writer_version = value,
                }
            }
            _ => positional.push(arg.clone()),
        }
    }
    match positional.len() {
        0 => Parsed::Print(Outcome {
            stdout: String::new(),
            stderr: format!(
                "Error: Missing expected argument '<input>'\nHelp:  <input>  Input video path (any AVFoundation-readable container, or a DXV3 .mov).\n{USAGE}"
            ),
            code: 64,
        }),
        1 => Parsed::Print(Outcome {
            stdout: String::new(),
            stderr: format!("Error: Missing expected argument '<output>'\nHelp:  <output>  Output file path.\n{USAGE}"),
            code: 64,
        }),
        2 => {
            a.input = positional[0].clone();
            a.output = positional[1].clone();
            Parsed::Run(Box::new(a))
        }
        _ => Parsed::Print(usage_error(&format!("Unexpected argument '{}'", positional[2]))),
    }
}

/// What `--verbose` prints besides the paths.
type Resolved = (EncodeRequest, OutputCodec, OutputSize, Option<CropRect>, Option<Range<u64>>, AlphaType);

/// The request a command line asks for, or Swift's usage error.
fn request(a: &Args) -> Result<Resolved, String> {
    let input = PathBuf::from(&a.input);
    if !input.exists() {
        return Err(format!("input file not found: {}", a.input));
    }
    let codec = parse_codec(&a.codec)?;
    let container = OutputContainer::from_raw(&a.container.to_lowercase()).ok_or_else(|| format!("invalid --container: {} (mov|mp4)", a.container))?;
    if !codec.allowed_containers().contains(&container) {
        let allowed: Vec<&str> = codec.allowed_containers().iter().map(|c| c.raw()).collect();
        return Err(format!("container {} is not allowed for {} (allowed: {})", container.raw(), swift_codec_description(codec), allowed.join(", ")));
    }
    if !(1..=64).contains(&a.chunks) {
        return Err(format!("--chunks must be in 1...64 (got {})", a.chunks));
    }
    let size = match (a.width, a.height) {
        (None, None) => OutputSize::Original,
        (Some(w), Some(h)) if w > 0 && h > 0 => {
            OutputSize::Custom { width: u32::try_from(w).unwrap_or(u32::MAX), height: u32::try_from(h).unwrap_or(u32::MAX) }
        }
        (Some(_), Some(_)) => return Err("--width/--height must be positive".into()),
        _ => return Err("--width and --height must be given together".into()),
    };
    let crop = match &a.crop {
        None => None,
        Some(s) => {
            let p = pieces(s);
            let v: Option<Vec<i64>> = if p.len() == 4 { p.iter().map(|x| swift_int(x)).collect() } else { None };
            let v = v.ok_or_else(|| format!("invalid --crop: {s} (expected x:y:w:h integers)"))?;
            // A negative or non-fitting rectangle reaches the pipeline, which refuses it as out of bounds.
            let u = |x: i64| u32::try_from(x).unwrap_or(u32::MAX);
            Some(CropRect { x: u(v[0]), y: u(v[1]), width: u(v[2]), height: u(v[3]) })
        }
    };
    let frames = match &a.trim {
        None => None,
        Some(s) => {
            let p = pieces(s);
            let lohi = if p.len() == 2 { swift_int(p[0]).zip(swift_int(p[1])) } else { None };
            match lohi {
                Some((lo, hi)) if lo >= 0 && hi > lo => Some(lo as u64..hi as u64),
                _ => return Err(format!("invalid --trim: {s} (expected start:end with 0 <= start < end)")),
            }
        }
    };
    let quality =
        ResizeQuality::from_raw(&a.resize_quality).ok_or_else(|| format!("invalid --resize-quality: {} (auto|nearest|bilinear|lanczos)", a.resize_quality))?;
    let aspect = AspectMode::from_raw(&a.aspect).ok_or_else(|| format!("invalid --aspect: {} (letterbox|distortToFill)", a.aspect))?;
    let alpha_type =
        AlphaType::from_raw(&a.alpha_type.to_lowercase()).ok_or_else(|| format!("invalid --alpha-type: {} (premultiplied|straight)", a.alpha_type))?;
    let req = EncodeRequest {
        source: input,
        output: PathBuf::from(&a.output),
        codec,
        container,
        video: VideoSettings::default(),
        output_size: size,
        resize_quality: quality,
        aspect,
        crop,
        frames: frames.clone(),
        writer_version: a.writer_version.clone(),
        hap_chunks: a.chunks as u32,
        alpha_type,
        // The CLI passes the source audio at its own rate (no rate option).
        audio: AudioPlan { enabled: a.audio, rate: AudioRate::Original },
        refined_bc4: false,
    };
    Ok((req, codec, size, crop, frames, alpha_type))
}

/// Swift's `URL(fileURLWithPath:).path`: a relative path resolved against the working directory.
fn absolute(p: &str) -> String {
    let path = std::path::Path::new(p);
    if path.is_absolute() {
        return p.to_owned();
    }
    std::env::current_dir().map(|d| d.join(path).display().to_string()).unwrap_or_else(|_| p.to_owned())
}

fn size_description(s: OutputSize) -> String {
    match s {
        OutputSize::Original => "original".into(),
        OutputSize::Preset(p) => format!("preset(GlEncCore.StandardResolution.{})", p.raw()),
        OutputSize::Custom { width, height } => format!("custom(width: {width}, height: {height})"),
    }
}

/// Run the CLI over `argv` (without the program name).
pub fn run(argv: &[String]) -> Outcome {
    let a = match parse(argv) {
        Parsed::Print(o) => return o,
        Parsed::Run(a) => a,
    };
    let (req, codec, size, crop, frames, alpha_type) = match request(&a) {
        Ok(r) => r,
        Err(m) => return usage_error(&m),
    };
    let mut err = String::new();
    if a.verbose {
        let crop_s = crop.map_or("none".to_owned(), |r| format!("({}.0, {}.0, {}.0, {}.0)", r.x, r.y, r.width, r.height));
        let trim_s = frames.as_ref().map_or("full".to_owned(), |r| format!("{}..<{}", r.start, r.end));
        let alpha_s = match alpha_type {
            AlphaType::Premultiplied => "Premultiplied",
            AlphaType::Straight => "Straight",
        };
        err.push_str(&format!(
            "glenc-cli encode\n  input:   {}\n  output:  {}\n  codec:   {}\n  size:    {}\n  crop:    {crop_s}\n  trim:    {trim_s}\n  alpha type (DXV source): {alpha_s}\n",
            absolute(&a.input),
            absolute(&a.output),
            swift_codec_description(codec),
            size_description(size)
        ));
    }
    match encode(&req, &|_| {}, &AtomicBool::new(false)) {
        Ok(o) => {
            if let Some(w) = o.audio_warning {
                // Swift prints the read-side warning (`warning: audio unavailable: …`) before the encode.
                err.push_str(&format!("warning: {}\n", w.replacen("Audio unavailable", "audio unavailable", 1)));
            }
            Outcome { stdout: format!("{}\n", a.output), stderr: err, code: 0 }
        }
        Err(e) => {
            err.push_str(&format!("error: encode failed: {e}\n"));
            Outcome { stdout: String::new(), stderr: err, code: 1 }
        }
    }
}
