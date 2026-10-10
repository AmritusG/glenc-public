import Foundation
import AVFoundation

/// Frame timing of a video track: its exact rate and where every frame starts
/// on the movie timeline. The one rule for every app that seeks, steps,
/// counts or encodes frames from an AVFoundation track (Glance's AV path;
/// CueGlance, GlEnc and MaCrate carry earlier copies — see CLAUDE.md).
///
/// **Frame times.** When the track provides sample cursors, every sample's
/// presentation time is read and mapped through the track's edit list onto
/// the movie timeline (H.264 with B-frames stores media times 2 frames ahead;
/// the edit list maps them back to 0). `time(ofFrame: n)` is then frame n's
/// real start, so a zero-tolerance seek there always shows frame n — also on
/// jittered timing, where a frame can start a tick AFTER its place on the
/// N / fps grid (a seek to the grid shows the previous frame; measured on
/// `jitter25_late.mov`: 4 / 40 wrong on the grid, 0 / 40 on the real
/// times). Without a sample table the times are the grid N x frame duration.
///
/// **Rate**, as an exact rational, first rule that applies:
///   1. the mean rate — sample count / the samples' summed duration in
///      their own timescale (exact), else / the track duration — snapped to
///      the nearest standard rate when within 0.1 % (GlEnc 1.5.0, which
///      divides by the track duration: stored at the movie timescale, 1/1000
///      s, that reads a 40-frame 60 fps clip as 59.94 and a 40-frame 30 fps
///      one as 29.97 — half a millisecond is 0.1 % of 0.67 s);
///   2. the dominant sample duration, snapped the same way (GlEnc 1.5.0);
///   3. minFrameDuration, when it agrees with nominalFrameRate within 0.2 %
///      (CueGlance 1.3.0) — exact constant-rate tracks at a non-standard rate;
///   4. nominalFrameRate, snapped when standard;
///   5. minFrameDuration alone; else 30.
/// minFrameDuration is the SHORTEST sample, not the frame period: a 25 fps
/// ProRes with 23 / 24 / 25-tick samples at 1/600 reads 26.09 fps from it,
/// a 30 fps one with 19 / 20 / 21 ticks 31.58 fps. Where the two earlier
/// rules differ (non-standard, variable timing: GlEnc fell back to
/// minFrameDuration, CueGlance to the nominal rate), the nominal (average)
/// rate wins: it keeps rate x duration = frame count.
public struct FrameTiming: Equatable {

    public enum Source: String {
        case meanRate, dominantDelta, minFrameDuration, nominal, fallback
    }

    /// Frames per second = `rateNumerator / rateDenominator`, exact
    /// (30000 / 1001, not 29.97).
    public let rateNumerator: Int32
    public let rateDenominator: Int64
    public let source: Source
    /// Start of every frame on the movie timeline, presentation order;
    /// empty when the track has no sample table (then the grid is used).
    public let frameTimes: [CMTime]
    public let frameCount: Int

    public var fps: Double { Double(rateNumerator) / Double(rateDenominator) }

    /// One frame period, exact (e.g. 1001 / 30000).
    public var frameDuration: CMTime { CMTime(value: rateDenominator, timescale: rateNumerator) }

    public init(rateNumerator: Int32, rateDenominator: Int64, source: Source,
                frameTimes: [CMTime] = [], frameCount: Int) {
        self.rateNumerator = rateNumerator
        self.rateDenominator = rateDenominator
        self.source = source
        self.frameTimes = frameTimes
        self.frameCount = frameTimes.isEmpty ? max(0, frameCount) : frameTimes.count
    }

    /// Index of the last frame (0 for an empty track).
    public var lastFrame: Int { max(0, frameCount - 1) }

    /// Start of frame `n` (clamped to the track), exact.
    public func time(ofFrame n: Int) -> CMTime {
        let n = frameCount > 0 ? min(max(0, n), lastFrame) : max(0, n)
        if !frameTimes.isEmpty { return frameTimes[n] }
        return CMTime(value: Int64(n) * rateDenominator, timescale: rateNumerator)
    }

    /// The frame showing at `time`: the last frame starting at or before it
    /// (floor; a frame's own start maps to that frame). Clamped to the track.
    public func frame(at time: CMTime) -> Int {
        guard time.isValid, time.isNumeric else { return 0 }
        if !frameTimes.isEmpty {
            var lo = 0, hi = frameTimes.count - 1
            if CMTimeCompare(time, frameTimes[0]) < 0 { return 0 }
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if CMTimeCompare(frameTimes[mid], time) <= 0 { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }
        // floor(t x num / den) in exact integer arithmetic on the time's ticks.
        let t = CMTimeConvertScale(time, timescale: rateNumerator, method: .roundTowardNegativeInfinity)
        let f = Int(max(0, t.value) / rateDenominator)
        return frameCount > 0 ? min(f, lastFrame) : f
    }

    /// The frame showing at `seconds` (floor).
    public func frame(atSeconds seconds: Double) -> Int {
        guard seconds.isFinite else { return 0 }
        return frame(at: CMTime(seconds: max(0, seconds) + 1e-9, preferredTimescale: 1_000_000_000))
    }

    /// The frame whose start is nearest to `seconds` (where a click or a
    /// typed time should land).
    public func nearestFrame(toSeconds seconds: Double) -> Int {
        let f = frame(atSeconds: seconds)
        guard frameCount == 0 || f < lastFrame else { return f }
        let a = time(ofFrame: f).seconds, b = time(ofFrame: f + 1).seconds
        return abs(b - seconds) < abs(seconds - a) ? f + 1 : f
    }

    // MARK: - Rate

    /// Standard rates, exact.
    public static let standardRates: [(num: Int32, den: Int64)] = [
        (24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1),
        (48, 1), (50, 1), (60000, 1001), (60, 1), (100, 1), (120, 1),
    ]

    /// The nearest standard rate to `fps` when within 0.1 % of it (29.97 and
    /// 30 differ by 0.1 % too, so the nearest is chosen first).
    public static func snap(_ fps: Double) -> (num: Int32, den: Int64)? {
        guard fps.isFinite, fps > 0 else { return nil }
        let nearest = standardRates.min {
            abs(Double($0.num) / Double($0.den) - fps) < abs(Double($1.num) / Double($1.den) - fps)
        }!
        let r = Double(nearest.num) / Double(nearest.den)
        return abs(r - fps) / r <= 0.001 ? nearest : nil
    }

    /// The rate from the track's timing (rules in the type doc). `durations`
    /// are sample durations in `timescale` units, empty when unavailable.
    public static func rate(sampleDurations durations: [Int64], timescale: Int32, trackDuration: Double,
                            minFrameDuration: CMTime?, nominalFrameRate: Float)
        -> (num: Int32, den: Int64, source: Source) {
        let summed = timescale > 0 ? Double(durations.reduce(0, +)) / Double(timescale) : 0
        let span = summed > 0 ? summed : trackDuration
        if !durations.isEmpty, span > 0, let s = snap(Double(durations.count) / span) {
            return (s.num, s.den, .meanRate)
        }
        if timescale > 0, !durations.isEmpty {
            var counts: [Int64: Int] = [:]
            for d in durations where d > 0 { counts[d, default: 0] += 1 }
            if let dominant = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key,
               let s = snap(Double(timescale) / Double(dominant)) {
                return (s.num, s.den, .dominantDelta)
            }
        }
        let nominal = Double(nominalFrameRate)
        let minOK = minFrameDuration.map { $0.isValid && $0.isNumeric && $0.value > 0 && $0.timescale > 0 } ?? false
        if minOK, let m = minFrameDuration, nominal > 0, abs(m.seconds * nominal - 1) < 0.002 {
            return (m.timescale, m.value, .minFrameDuration)
        }
        if nominal > 0 {
            if let s = snap(nominal) { return (s.num, s.den, .nominal) }
            return (Int32((nominal * 1000).rounded()), 1000, .nominal)
        }
        if minOK, let m = minFrameDuration { return (m.timescale, m.value, .minFrameDuration) }
        return (30, 1, .fallback)
    }

    // MARK: - From a track

    /// Reads `track`'s sample table (presentation times mapped through the
    /// edit list, durations) and resolves its timing. Falls back to the grid
    /// when the track provides no sample cursors or an edit changes speed.
    public static func load(track: AVAssetTrack) async throws -> FrameTiming {
        let (nominal, minDuration, range, segments, cursors) = try await track.load(
            .nominalFrameRate, .minFrameDuration, .timeRange, .segments, .canProvideSampleCursors)
        let trackSeconds = range.duration.seconds.isFinite ? range.duration.seconds : 0

        var durations: [Int64] = []
        var timescale: Int32 = 0
        var times: [CMTime] = []
        if cursors, let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() {
            var mediaTimes: [CMTime] = []
            repeat {
                let d = cursor.currentSampleDuration
                if d.isValid, d.isNumeric {
                    durations.append(d.value)
                    timescale = d.timescale
                }
                mediaTimes.append(cursor.presentationTimeStamp)
            } while cursor.stepInDecodeOrder(byCount: 1) == 1
            times = movieTimes(mediaTimes, segments: segments) ?? []
        }
        let r = rate(sampleDurations: durations, timescale: timescale, trackDuration: trackSeconds,
                     minFrameDuration: minDuration, nominalFrameRate: nominal)
        let gridCount = Int((trackSeconds * Double(r.num) / Double(r.den)).rounded())
        return FrameTiming(rateNumerator: r.num, rateDenominator: r.den, source: r.source,
                           frameTimes: times, frameCount: gridCount)
    }

    /// Media presentation times -> sorted movie-timeline times through the
    /// edit list; samples outside every edit are dropped. nil when an edit
    /// plays at another speed (no 1:1 mapping) or nothing maps.
    static func movieTimes(_ media: [CMTime], segments: [AVAssetTrackSegment]) -> [CMTime]? {
        let edits = segments.filter { !$0.isEmpty }.map(\.timeMapping)
        if edits.isEmpty { return media.sorted { CMTimeCompare($0, $1) < 0 } }
        for e in edits where CMTimeCompare(e.source.duration, e.target.duration) != 0 { return nil }
        var out: [CMTime] = []
        out.reserveCapacity(media.count)
        for t in media {
            for e in edits where CMTimeRangeContainsTime(e.source, time: t) {
                out.append(CMTimeAdd(CMTimeSubtract(t, e.source.start), e.target.start))
            }
        }
        guard !out.isEmpty else { return nil }
        return out.sorted { CMTimeCompare($0, $1) < 0 }
    }
}
