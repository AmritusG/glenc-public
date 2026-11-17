//! HH:MM:SS:FF timecode (Swift `Timecode.swift`) and the In / Out popover's rules (`TimecodePopover.swift`).
//!
//! Non-drop SMPTE style with `:` between the fields; the frame field counts `0 ..< round(fps)` within each second, so
//! a 29.97 source shows over a 30-frame slot count (`Timecode.swift:8-12`).

/// The text with no frame rate (`Timecode.swift:17`).
pub const PLACEHOLDER: &str = "—:—:—:—";

/// The frame rate as the frame field counts it: rounded, at least 1 (`Timecode.swift:19`).
fn slots(fps: f64) -> i64 {
    (fps.round() as i64).max(1)
}

/// `Timecode.string(frame:fps:)`: a negative frame shows as 0; no frame rate shows [`PLACEHOLDER`].
pub fn string(frame: i64, fps: f64) -> String {
    if fps.is_nan() || fps <= 0.0 {
        return PLACEHOLDER.into();
    }
    let f = frame.max(0);
    let n = slots(fps);
    let total_seconds = f / n;
    let frames = f % n;
    format!("{:02}:{:02}:{:02}:{:02}", total_seconds / 3600, (total_seconds % 3600) / 60, total_seconds % 60, frames)
}

/// `Timecode.parse(_:fps:)`: four `:`-separated non-negative integers, spaces around the whole string tolerated;
/// out-of-range fields are not clamped (the caller clamps). `None` for anything else or no frame rate.
pub fn parse(s: &str, fps: f64) -> Option<i64> {
    if fps.is_nan() || fps <= 0.0 {
        return None;
    }
    let parts: Vec<&str> = s.trim().split(':').collect();
    let [h, m, sec, f] = parts.as_slice() else { return None };
    let field = |p: &str| p.parse::<i64>().ok().filter(|v| *v >= 0);
    let (h, m, sec, f) = (field(h)?, field(m)?, field(sec)?, field(f)?);
    let total_seconds = h.checked_mul(3600)?.checked_add(m.checked_mul(60)?)?.checked_add(sec)?;
    total_seconds.checked_mul(slots(fps))?.checked_add(f)
}

/// The popover's caption under the field (`TimecodePopover.swift:41`).
pub fn caption(fps: f64, total_frames: i64) -> String {
    format!("fps: {} — frames 0-{}", if fps.is_finite() { fps.round() as i64 } else { 0 }, (total_frames - 1).max(0))
}

/// The popover's Set / Return (`TimecodePopover.commit`, `:63-79`): the frame, or the message shown in red.
pub fn commit(text: &str, fps: f64, total_frames: i64) -> Result<i64, String> {
    if fps.is_nan() || fps <= 0.0 {
        return Err("Source frame rate unknown — can't parse timecode.".into());
    }
    let Some(frame) = parse(text, fps) else { return Err("Format: HH:MM:SS:FF (e.g. 00:01:30:15)".into()) };
    let last = (total_frames - 1).max(0);
    if !(0..=last).contains(&frame) {
        return Err(format!("Out of range. Frames must be 0–{last}."));
    }
    Ok(frame)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_hours_minutes_seconds_frames() {
        assert_eq!(string(0, 25.0), "00:00:00:00");
        assert_eq!(string(24, 25.0), "00:00:00:24");
        assert_eq!(string(25, 25.0), "00:00:01:00");
        assert_eq!(string(90 * 30 + 15, 30.0), "00:01:30:15");
        assert_eq!(string(3600 * 24 + 61 * 24 + 3, 24.0), "01:01:01:03");
    }

    #[test]
    fn fractional_rates_count_rounded_slots() {
        // 29.97 counts 30 slots a second; 23.976 counts 24; 59.94 counts 60.
        assert_eq!(string(30, 30000.0 / 1001.0), "00:00:01:00");
        assert_eq!(string(29, 30000.0 / 1001.0), "00:00:00:29");
        assert_eq!(string(48, 24000.0 / 1001.0), "00:00:02:00");
        assert_eq!(string(61, 60000.0 / 1001.0), "00:00:01:01");
        // 12.5 rounds half away from zero (Swift's `rounded()`): 13 slots.
        assert_eq!(string(13, 12.5), "00:00:01:00");
    }

    #[test]
    fn no_rate_shows_the_placeholder_and_negative_frames_show_zero() {
        assert_eq!(string(10, 0.0), PLACEHOLDER);
        assert_eq!(string(10, -5.0), PLACEHOLDER);
        assert_eq!(string(10, f64::NAN), PLACEHOLDER);
        assert_eq!(string(-7, 25.0), "00:00:00:00");
        // A rate below one rounds to at least one slot.
        assert_eq!(string(3, 0.4), "00:00:03:00");
    }

    #[test]
    fn parses_back_to_the_frame() {
        assert_eq!(parse("00:01:30:15", 30.0), Some(2715));
        assert_eq!(parse("  00:00:01:00 \n", 25.0), Some(25));
        assert_eq!(parse("01:00:00:00", 30000.0 / 1001.0), Some(108_000));
        for f in [0, 1, 29, 30, 1799, 1800, 107_999, 1_000_003] {
            assert_eq!(parse(&string(f, 29.97), 29.97), Some(f), "round trip of {f}");
        }
    }

    #[test]
    fn out_of_range_fields_are_not_clamped() {
        // 99 frames at 25 fps is past the second: kept as typed (the caller clamps).
        assert_eq!(parse("00:00:00:99", 25.0), Some(99));
        assert_eq!(parse("00:00:75:00", 25.0), Some(75 * 25));
    }

    #[test]
    fn rejects_what_swift_rejects() {
        assert_eq!(parse("00:00:00", 25.0), None);
        assert_eq!(parse("00:00:00:00:00", 25.0), None);
        assert_eq!(parse("00::00:00", 25.0), None);
        assert_eq!(parse("00:00:00:-1", 25.0), None);
        assert_eq!(parse("aa:00:00:00", 25.0), None);
        assert_eq!(parse("00: 01:00:00", 25.0), None);
        assert_eq!(parse("", 25.0), None);
        assert_eq!(parse("00:00:01:00", 0.0), None);
        assert_eq!(parse("9223372036854775807:00:00:00", 25.0), None, "overflow is no frame, not a crash");
    }

    #[test]
    fn the_popover_commit_messages() {
        assert_eq!(commit("00:00:01:00", 25.0, 100), Ok(25));
        assert_eq!(commit("00:00:03:23", 25.0, 100), Ok(98));
        assert_eq!(commit("00:00:03:24", 25.0, 100), Ok(99));
        assert_eq!(commit("00:00:04:00", 25.0, 100), Err("Out of range. Frames must be 0–99.".into()));
        assert_eq!(commit("1:2", 25.0, 100), Err("Format: HH:MM:SS:FF (e.g. 00:01:30:15)".into()));
        assert_eq!(commit("00:00:00:00", 0.0, 100), Err("Source frame rate unknown — can't parse timecode.".into()));
        assert_eq!(caption(29.97, 300), "fps: 30 — frames 0-299");
        assert_eq!(caption(25.0, 0), "fps: 25 — frames 0-0");
    }
}
