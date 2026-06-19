// SPDX-License-Identifier: MIT
import Foundation

/// HH:MM:SS:FF timecode formatting and parsing. SMPTE-style with `:`
/// as the field separator. The frame field counts 0..floor(fps)-1
/// within each second.
///
/// fps is treated as integer-rounded for the frame field — a 29.97
/// source displays as HH:MM:SS:FF over a 30-frame slot count, which
/// is what VJ-tool conventions use (Resolume, Premiere display the
/// same way for non-drop-frame counts). The conversion is monotonic
/// in the source frame index, so timeline scrubbing stays correct.
enum Timecode {

    /// `nil` fps → "—:—:—:—" placeholder. `frame < 0` clamped to 0.
    static func string(frame: Int, fps: Double) -> String {
        guard fps > 0 else { return "—:—:—:—" }
        let f = max(0, frame)
        let fpsRounded = max(1, Int(fps.rounded()))
        let totalSeconds = f / fpsRounded
        let frames = f % fpsRounded
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }

    /// Parse a HH:MM:SS:FF string back to a frame index. Tolerates
    /// extra spaces. Returns `nil` if any field fails to parse or
    /// fps ≤ 0. Out-of-range fields are NOT clamped here — the
    /// caller is responsible for clamping into the clip's valid range.
    static func parse(_ s: String, fps: Double) -> Int? {
        guard fps > 0 else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        guard let h = Int(parts[0]),
              let m = Int(parts[1]),
              let sec = Int(parts[2]),
              let f = Int(parts[3]),
              h >= 0, m >= 0, sec >= 0, f >= 0 else { return nil }
        let fpsRounded = max(1, Int(fps.rounded()))
        let totalSeconds = h * 3600 + m * 60 + sec
        return totalSeconds * fpsRounded + f
    }
}
