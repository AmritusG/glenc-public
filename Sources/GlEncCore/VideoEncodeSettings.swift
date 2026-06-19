// SPDX-License-Identifier: MIT
import Foundation
import AVFoundation

/// Multi-Format Phase 2a — rate-control + profile knobs shared by the
/// VideoToolbox inter-frame codecs (H.264 / HEVC). Carried as a field on
/// `EncodeJob` (beside `outputContainer`) and applied to the
/// `AVAssetWriterInput` output settings under
/// `AVVideoCompressionPropertiesKey`. ProRes ignores these (its sink is
/// built with no compression properties — bytes/behavior unchanged).
public struct VideoEncodeSettings: Hashable, Sendable, Codable {

    /// How the encoder targets bitrate. Constant-quality (`AVVideoQualityKey`,
    /// honored for H.264/HEVC on Apple-silicon VideoToolbox) keeps perceptual
    /// quality steady at a variable size; bitrate (`AVVideoAverageBitRateKey`)
    /// targets an average Mbps. Quality is the default — "pick codec, encode"
    /// stays good without tuning.
    public enum RateControl: Hashable, Sendable, Codable {
        case quality(Double)   // 0...1 constant quality
        case bitrate(Double)   // average target, Mbps

        public var isQuality: Bool { if case .quality = self { return true }; return false }
    }

    /// H.264 profile (ignored by HEVC, which stays Main/auto this sub-phase).
    public enum H264Profile: String, CaseIterable, Hashable, Sendable, Codable {
        case baseline, main, high

        public var label: String {
            switch self {
            case .baseline: return "Baseline"
            case .main:     return "Main"
            case .high:     return "High"
            }
        }

        /// AVFoundation profile-level constant (auto level).
        public var profileLevel: String {
            switch self {
            case .baseline: return AVVideoProfileLevelH264BaselineAutoLevel
            case .main:     return AVVideoProfileLevelH264MainAutoLevel
            case .high:     return AVVideoProfileLevelH264HighAutoLevel
            }
        }
    }

    public var rateControl: RateControl
    /// Max keyframe interval in frames. 0 = leave to the codec default.
    public var keyframeIntervalFrames: Int
    public var h264Profile: H264Profile

    public init(rateControl: RateControl = .quality(0.6),
                keyframeIntervalFrames: Int = 0,
                h264Profile: H264Profile = .high) {
        self.rateControl = rateControl
        self.keyframeIntervalFrames = keyframeIntervalFrames
        self.h264Profile = h264Profile
    }

    /// Sane defaults — an untouched job "just encodes" at good quality.
    public static let `default` = VideoEncodeSettings()

    /// Build the `AVVideoCompressionPropertiesKey` payload. `includeH264Profile`
    /// is true only for the H.264 codec (HEVC leaves profile to the encoder).
    public func compressionProperties(includeH264Profile: Bool) -> [String: Any] {
        var props: [String: Any] = [:]
        switch rateControl {
        case .quality(let q): props[AVVideoQualityKey] = q
        case .bitrate(let mbps): props[AVVideoAverageBitRateKey] = Int(mbps * 1_000_000)
        }
        if keyframeIntervalFrames > 0 {
            props[AVVideoMaxKeyFrameIntervalKey] = keyframeIntervalFrames
        }
        if includeH264Profile {
            props[AVVideoProfileLevelKey] = h264Profile.profileLevel
        }
        return props
    }
}
