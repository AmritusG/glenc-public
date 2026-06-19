// SPDX-License-Identifier: MIT
import Foundation
import AVFoundation
import CoreMedia

/// Multi-Format Phase 4 — audio pass-through support.
///
/// Audio is a TRACK-LEVEL concern, deliberately kept OUT of the
/// per-frame `FrameSink.consume(PixelFrame)` video path: a sink that
/// carries audio reads it from the source URL itself (via
/// `SourceAudioReader`) at finish time. This keeps `EncodePipeline` and
/// the `SinkFactory` signature untouched — the video byte path is
/// unaffected and the DXV byte-identity gate holds by construction (a
/// sink built with no `AudioPlan` never touches audio).

/// Target output sample rate. `.original` = decode-to-PCM at the source
/// rate (no resample); the explicit rates resample on read.
public enum AudioRate: Hashable, Sendable, Codable, CaseIterable {
    case original
    case hz44100
    case hz48000
    case hz88200
    case hz96000

    public static var allCases: [AudioRate] {
        [.original, .hz44100, .hz48000, .hz88200, .hz96000]
    }

    /// Target Hz, or nil for `.original` (no resample).
    public var hz: Int? {
        switch self {
        case .original: return nil
        case .hz44100:  return 44100
        case .hz48000:  return 48000
        case .hz88200:  return 88200
        case .hz96000:  return 96000
        }
    }

    public var label: String {
        switch self {
        case .original: return "Original"
        case .hz44100:  return "44.1 kHz"
        case .hz48000:  return "48 kHz"
        case .hz88200:  return "88.2 kHz"
        case .hz96000:  return "96 kHz"
        }
    }

    /// Stable Int for persistence — 0 = `.original`, else the Hz value.
    public var persistInt: Int { hz ?? 0 }

    public static func from(persistInt v: Int) -> AudioRate {
        switch v {
        case 44100: return .hz44100
        case 48000: return .hz48000
        case 88200: return .hz88200
        case 96000: return .hz96000
        default:    return .original
        }
    }
}

/// Per-job audio plan: whether to carry source audio, and at what rate.
/// Default = carry (ON), Original rate (Alley parity).
public struct AudioPlan: Hashable, Sendable, Codable {
    public var enabled: Bool
    public var rate: AudioRate
    public init(enabled: Bool = true, rate: AudioRate = .original) {
        self.enabled = enabled
        self.rate = rate
    }
    public static let `default` = AudioPlan()
}

/// Resolved PCM stream description (after decode/resample).
public struct AudioStreamInfo: Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerChannel: Int   // 32 for the in32 DXV path
    public init(sampleRate: Int, channels: Int, bitsPerChannel: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerChannel = bitsPerChannel
    }
    /// Bytes per interleaved audio frame (all channels, one sample tick).
    public var bytesPerFrame: Int { channels * (bitsPerChannel / 8) }
}

public enum SourceAudioError: Error, CustomStringConvertible {
    case readerInitFailed(Error)
    case readerStartFailed
    /// Fix-Brief 2 (C) — the source ASBD declares a channel count outside
    /// the supported range (e.g. a corrupt 0xFFFFFFFF). Surfaced as a job
    /// warning rather than written as a near-empty/garbled audio trak.
    case unsupportedChannelCount(Int)
    /// Fix-Brief 2 (D) — decodable, non-empty audio whose sample rate could
    /// not be determined from any sample buffer OR the track-level format
    /// description. Surfaced rather than mislabeled as a hardcoded 48 kHz.
    case undeterminedSampleRate
    public var description: String {
        switch self {
        case .readerInitFailed(let e): return "SourceAudioReader: reader init failed: \(e)"
        case .readerStartFailed:       return "SourceAudioReader: startReading() failed"
        case .unsupportedChannelCount(let c):
            return "SourceAudioReader: source declares \(c) audio channels (supported: 1…\(SourceAudioReader.maxChannels))"
        case .undeterminedSampleRate:
            return "SourceAudioReader: could not determine the source audio sample rate"
        }
    }
}

/// Reads a source's audio track as interleaved 32-bit signed little-endian
/// PCM (the `in32` layout Resolume/Alley uses for DXV). Resamples + (with
/// channel pass-through) carries the source channel count via the
/// AVAssetReader output settings. Used by the DXV/HAP audio trak; the
/// AVAssetWriter delivery sinks pump audio through their own reader.
public enum SourceAudioReader {

    /// Fix-Brief 2 (C) — sane ceiling on source channel count. Generous:
    /// any real layout (mono…7.1…22.2…Atmos beds) is ≤ 24; 64 leaves wide
    /// headroom while rejecting pathological values (e.g. a corrupt
    /// 0xFFFFFFFF). The floor is 1. AAC's own hard max is 48; LPCM more.
    public static let maxChannels = 64

    /// Pure: is a declared channel count usable? (1…maxChannels). Unit seam.
    public static func channelsSupported(_ n: Int) -> Bool {
        n >= 1 && n <= maxChannels
    }

    /// Pure: resolve the output sample rate. `primary` is the rate already
    /// resolved from the explicit resample target or the per-sample-buffer
    /// ASBD (0 if neither). Falls back to the track-level nominal rate; if
    /// still unknown and there IS decodable (non-empty) PCM, throws rather
    /// than mislabeling as a hardcoded 48 kHz — Fix-Brief 2 (D). Empty PCM
    /// (zero-frame track) is benign: returns 48000 (moot — gated out
    /// downstream by the !pcm.isEmpty check). Unit seam.
    public static func resolveSampleRate(
        primary: Int, trackNominal: Int, hasNonEmptyPCM: Bool
    ) throws -> Int {
        if primary > 0 { return primary }
        if trackNominal > 0 { return trackNominal }
        if hasNonEmptyPCM { throw SourceAudioError.undeterminedSampleRate }
        return 48000
    }

    /// True iff the URL has at least one audio track.
    public static func hasAudio(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        return !tracks.isEmpty
    }

    /// Decode the source audio to interleaved s32le PCM. `targetRate` nil
    /// = source rate (Original). Channels are pass-through (the source's
    /// own count). Returns nil if the source has no audio track.
    public static func readInterleavedPCM(
        _ url: URL, targetRate: Int?
    ) async throws -> (info: AudioStreamInfo, pcm: Data, frameCount: Int)? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }

        // Discover the source channel count (pass-through). AVAssetReader
        // needs a concrete output ASBD; we read the source's channel count
        // from its format description and keep it.
        var channels = 2
        // Fix-Brief 2 (D) — also capture the track-level nominal sample rate
        // here so an unreadable per-sample-buffer ASBD later falls back to a
        // REAL rate instead of a hardcoded 48 kHz.
        var trackNominalRate = 0
        if let fmtDescs = try? await track.load(.formatDescriptions),
           let fmt = fmtDescs.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
            channels = Int(asbd.pointee.mChannelsPerFrame)
            trackNominalRate = Int(asbd.pointee.mSampleRate)
        }
        if channels < 1 { channels = 1 }
        // Fix-Brief 2 (C) — reject a pathological/unsupported channel count
        // (e.g. a corrupt 0xFFFFFFFF) rather than passing it to AVAssetReader
        // and writing a near-empty/garbled trak. The caller turns this into a
        // surfaced "audio unavailable" warning and keeps the video.
        guard SourceAudioReader.channelsSupported(channels) else {
            throw SourceAudioError.unsupportedChannelCount(channels)
        }

        // Build LPCM output settings: s32, little-endian, interleaved.
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: channels,
        ]
        if let target = targetRate { settings[AVSampleRateKey] = target }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw SourceAudioError.readerInitFailed(error) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { throw SourceAudioError.readerStartFailed }
        reader.add(output)
        guard reader.startReading() else { throw SourceAudioError.readerStartFailed }

        // Accumulate into memory until a cap, then SPILL to a temp file
        // (the v0.10.1 leak lesson — never unbounded). Past the cap, the
        // already-buffered Data is flushed to the file and subsequent
        // samples append straight to disk. At the end the file is memory-
        // mapped and immediately unlinked: the mapping stays valid, RSS is
        // OS-paged (not pinned), and the file space frees when the Data is
        // released. Typical VJ clips stay in memory.
        let spillThreshold = 256 * 1024 * 1024
        var pcm = Data()
        var spillURL: URL?
        var spillHandle: FileHandle?
        var resolvedRate = targetRate ?? 0

        // Fix-Brief 3 (F1) — guarantee the spill handle is closed and the
        // temp file removed on EVERY exit, including a throw mid-write (disk
        // full / EACCES) that would otherwise skip the explicit cleanup
        // below. The normal path nils both after its own close+mmap+remove,
        // so this defer is a no-op there (no double-close / double-remove).
        defer {
            if let h = spillHandle { try? h.close() }
            if let u = spillURL { try? FileManager.default.removeItem(at: u) }
        }

        func ensureSpill() throws {
            guard spillHandle == nil else { return }
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("glenc-audio-spill-\(UUID().uuidString).pcm")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let fh = try FileHandle(forWritingTo: url)
            if !pcm.isEmpty { try fh.write(contentsOf: pcm); pcm = Data() }
            spillURL = url; spillHandle = fh
        }

        while let sb = output.copyNextSampleBuffer() {
            if resolvedRate == 0,
               let fmt = CMSampleBufferGetFormatDescription(sb),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
                resolvedRate = Int(asbd.pointee.mSampleRate)
            }
            if let bb = CMSampleBufferGetDataBuffer(sb) {
                let len = CMBlockBufferGetDataLength(bb)
                if len > 0 {
                    var tmp = [UInt8](repeating: 0, count: len)
                    CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &tmp)
                    if let fh = spillHandle {
                        try fh.write(contentsOf: Data(tmp))
                    } else {
                        pcm.append(contentsOf: tmp)
                        if pcm.count >= spillThreshold { try ensureSpill() }
                    }
                }
            }
        }
        var result = pcm
        if let fh = spillHandle, let url = spillURL {
            try? fh.synchronize(); try? fh.close()
            // mmap then unlink — mapping survives, RSS stays paged.
            result = (try? Data(contentsOf: url, options: .alwaysMapped)) ?? Data()
            try? FileManager.default.removeItem(at: url)
            // Normal-path cleanup done — disarm the F1 defer (no double-act).
            spillHandle = nil; spillURL = nil
        }
        // Fix-Brief 2 (D) — resolve the rate via the track-level fallback;
        // throw (→ surfaced warning) if real audio has no determinable rate,
        // instead of silently mislabeling it 48 kHz.
        resolvedRate = try SourceAudioReader.resolveSampleRate(
            primary: resolvedRate, trackNominal: trackNominalRate,
            hasNonEmptyPCM: !result.isEmpty)
        let info = AudioStreamInfo(sampleRate: resolvedRate, channels: channels, bitsPerChannel: 32)
        let frameCount = info.bytesPerFrame > 0 ? result.count / info.bytesPerFrame : 0
        return (info, result, frameCount)
    }
}
