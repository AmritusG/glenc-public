// SPDX-License-Identifier: MIT
import Foundation

/// v1.5.0 — the frame rate of a source track, from its sample timing.
///
/// `AVAssetTrack.minFrameDuration` is the SHORTEST sample duration, not the
/// frame period: a 25 fps ProRes whose samples are 24 / 600 s with jittered
/// 23 / 25 pairs (timescale 600; 297 × 24, 19 × 23, 19 × 25 — the real
/// Indigofera 4444 export) has minFrameDuration 23/600 → 26.09 fps, which
/// the writer refuses. The rate is instead taken, in order, from:
///   1. sample count / track duration (the mean rate), snapped to a
///      standard rate when within `tolerance` of one;
///   2. the dominant sample duration (timescale / most common delta),
///      snapped the same way;
///   3. otherwise the pre-v1.5.0 rule: minFrameDuration (timescale /
///      value), else nominalFrameRate — so non-standard and variable-rate
///      sources behave exactly as before.
/// Snapping returns the exact rational (30000/1001, not 29.97), which the
/// writer turns into its timescale / delta pair.
public enum FrameRateResolver {

    /// Standard rates, as exact rationals.
    public static let standardRates: [(num: Int, den: Int)] = [
        (24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1),
        (48, 1), (50, 1), (60000, 1001), (60, 1), (100, 1), (120, 1),
    ]

    /// Relative tolerance for snapping: 0.1 %. 29.97 vs 30 differ by
    /// 0.1 % too, so each measured rate is matched to its NEAREST standard
    /// rate first and only accepted when that one is within tolerance.
    public static let tolerance = 0.001

    /// The nearest standard rate to `fps`, as an exact value, when within
    /// `tolerance`; else nil.
    public static func snap(_ fps: Double) -> Double? {
        guard fps.isFinite, fps > 0 else { return nil }
        let nearest = standardRates
            .map { Double($0.num) / Double($0.den) }
            .min { abs($0 - fps) < abs($1 - fps) }!
        return abs(nearest - fps) / nearest <= tolerance ? nearest : nil
    }

    public enum Source: String { case meanRate, dominantDelta, minFrameDuration, nominal }

    /// Resolve the rate (see the type doc). `durations` are the per-sample
    /// durations in `timescale` units (empty when unavailable).
    public static func resolve(sampleDurations durations: [Int64], timescale: Int32,
                               trackDuration: Double,
                               minFrameDuration: (value: Int64, timescale: Int32)?,
                               nominalFrameRate: Float) -> (fps: Double, source: Source) {
        if !durations.isEmpty, trackDuration > 0,
           let s = snap(Double(durations.count) / trackDuration) {
            return (s, .meanRate)
        }
        if timescale > 0, !durations.isEmpty {
            var counts: [Int64: Int] = [:]
            for d in durations where d > 0 { counts[d, default: 0] += 1 }
            if let dominant = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key,
               let s = snap(Double(timescale) / Double(dominant)) {
                return (s, .dominantDelta)
            }
        }
        if let m = minFrameDuration, m.value > 0, m.timescale > 0 {
            return (Double(m.timescale) / Double(m.value), .minFrameDuration)
        }
        return (Double(nominalFrameRate), .nominal)
    }
}
