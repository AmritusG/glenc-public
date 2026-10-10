// SPDX-License-Identifier: MIT
//
// v1.6.0 — what a source's alpha means, and the per-source "Alpha Type"
// switch (Amrit, 2026-10-10: "Switch.").
//
// A DXV file does not say whether its colour is straight or premultiplied
// by alpha (DXVKit spec DXV_FORMAT.md 8.5: no field in the packet, the
// sample description or the atoms). Resolume Arena lets the user choose per
// clip with "Alpha Type", default Premultiplied; GlEnc does the same for DXV
// sources: Premultiplied -> the colour is un-premultiplied on read, before
// any encode (DXV, HAP, ProRes, H.264 ...); Straight -> passed through.
//
// Sources whose format states the convention are read as the format says
// and the switch is shown disabled with that value: HAP alpha (Hap5 / HapM /
// HapA) is straight, as GlEnc and Glance write and read it; ProRes 4444 and
// HEVC with alpha are decoded by AVFoundation (straight unless the format
// description says premultiplied).
//
// The hint is spec 8.5's pixel metric: on sample pixels with 8 < alpha <
// 200 (every 7th pixel), the share whose max(R, G, B) exceeds alpha + 24.
// Premultiplied colour cannot exceed alpha (apart from block error), so a
// share near 0 "looks premultiplied" (dark straight content can look the
// same: a reading, not proof) and a share of a few per cent "looks
// straight". It never changes the setting by itself.

import Foundation
import AVFoundation
import CoreMedia
import GlanceCore
import DXVKit

/// Arena's names and default.
public enum SourceAlphaType: String, CaseIterable, Codable, Sendable {
    case premultiplied
    case straight

    public static let `default`: SourceAlphaType = .premultiplied

    public var label: String {
        switch self {
        case .premultiplied: return "Premultiplied"
        case .straight: return "Straight"
        }
    }
}

/// Spec 8.5's reading of a frame's colour.
public enum AlphaLook: Equatable, Sendable {
    case looksPremultiplied
    case looksStraight
    case cantTell

    public var label: String {
        switch self {
        case .looksPremultiplied: return "looks premultiplied"
        case .looksStraight: return "looks straight"
        case .cantTell: return "can't tell"
        }
    }
}

public enum AlphaLookMetric {
    /// Fewer semi-transparent sample pixels than this cannot be classified
    /// (the spec's W4 survey: 500).
    public static let minimumSamples = 500
    /// At or below this share: looks premultiplied (spec: "near 0"; the
    /// AME / premultiplied files measured 0.0 – 0.1 %).
    public static let premultipliedAtMost = 0.005
    /// At or above this share: looks straight (spec: "clearly above a few
    /// per cent"; the straight files measured 8.6 – 98.4 %).
    public static let straightAtLeast = 0.03

    /// Counts over one RGBA frame (straight bytes as decoded, no alpha
    /// processing): semi-transparent samples, and those whose max(R, G, B)
    /// exceeds alpha + 24.
    public static func count(rgba: UnsafeRawBufferPointer, pixelCount: Int) -> (samples: Int, exceeding: Int) {
        let p = rgba.bindMemory(to: UInt8.self)
        var samples = 0, exceeding = 0
        var i = 0
        while i < pixelCount {
            let a = Int(p[i * 4 + 3])
            if a > 8 && a < 200 {
                samples += 1
                if max(Int(p[i * 4]), Int(p[i * 4 + 1]), Int(p[i * 4 + 2])) > a + 24 { exceeding += 1 }
            }
            i += 7
        }
        return (samples, exceeding)
    }

    public static func classify(samples: Int, exceeding: Int) -> AlphaLook {
        guard samples >= minimumSamples else { return .cantTell }
        let share = Double(exceeding) / Double(samples)
        if share <= premultipliedAtMost { return .looksPremultiplied }
        if share >= straightAtLeast { return .looksStraight }
        return .cantTell
    }
}

/// What a source's alpha is, for the Alpha Type control.
public struct SourceAlphaReport: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// No alpha: the control is not shown.
        case none
        /// A DXV source with alpha: the file does not say; the user chooses.
        case choosable
        /// The format states it; the control shows this value, disabled.
        case stated(SourceAlphaType, by: String)
    }
    public let kind: Kind
    /// Spec 8.5 reading of the first frames (nil when not measured).
    public let look: AlphaLook?
    /// Semi-transparent sample pixels and the share exceeding alpha + 24.
    public let samples: Int
    public let share: Double

    public init(kind: Kind, look: AlphaLook? = nil, samples: Int = 0, share: Double = 0) {
        self.kind = kind; self.look = look; self.samples = samples; self.share = share
    }
}

public enum SourceAlpha {

    /// Probe a source: DXV with alpha -> choosable + the hint on its first
    /// and middle frames; HAP alpha -> stated straight; AVFoundation alpha
    /// -> stated by the format description; else none.
    public static func probe(_ url: URL) async -> SourceAlphaReport {
        if let cc = DXVDetector.compressorFourCC(at: url), dxvSourceFourCCs.contains(cc) {
            return (try? probeDXV(url)) ?? SourceAlphaReport(kind: .none)
        }
        if let hap = HAPDetector.compressorFourCCIfHAP(at: url) {
            return ["Hap5", "HapM", "HapA"].contains(hap)
                ? SourceAlphaReport(kind: .stated(.straight, by: "HAP"))
                : SourceAlphaReport(kind: .none)
        }
        return await probeAVFoundation(url)
    }

    /// DXV: alpha variants only (DXT5, YG10, legacy DXT5).
    public static func probeDXV(_ url: URL) throws -> SourceAlphaReport {
        let movie = try DXVMovie(url: url)
        guard movie.frameCount > 0, movie.hasAlpha else { return SourceAlphaReport(kind: .none) }
        let frame = DXVFrame()
        var samples = 0, exceeding = 0
        for index in Set([0, movie.frameCount / 2]).sorted() {
            try movie.decodeBlocks(at: index, into: frame)
            let rgba = try frame.rgba()
            let c = rgba.withUnsafeBytes { AlphaLookMetric.count(rgba: $0, pixelCount: rgba.count / 4) }
            samples += c.samples; exceeding += c.exceeding
        }
        return SourceAlphaReport(kind: .choosable,
                                 look: AlphaLookMetric.classify(samples: samples, exceeding: exceeding),
                                 samples: samples,
                                 share: samples > 0 ? Double(exceeding) / Double(samples) : 0)
    }

    /// AVFoundation sources: the format description's alpha flag and, when
    /// present, its alpha-channel mode.
    static func probeAVFoundation(_ url: URL) async -> SourceAlphaReport {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fmt = (try? await track.load(.formatDescriptions))?.first else {
            return SourceAlphaReport(kind: .none)
        }
        let exts = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] ?? [:]
        let containsAlpha = (exts[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? NSNumber)?.boolValue
            ?? ["ap4h", "ap4x"].contains(fourCC(CMFormatDescriptionGetMediaSubType(fmt)))
        guard containsAlpha else { return SourceAlphaReport(kind: .none) }
        let mode = exts[kCMFormatDescriptionExtension_AlphaChannelMode as String] as? String
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(fmt))
        let name = ["ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ", "hvc1": "HEVC", "hev1": "HEVC"][codec] ?? codec
        if mode == (kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha as String) {
            return SourceAlphaReport(kind: .stated(.premultiplied, by: name))
        }
        return SourceAlphaReport(kind: .stated(.straight, by: name))
    }

    static func fourCC(_ v: FourCharCode) -> String {
        String(bytes: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)],
               encoding: .ascii) ?? ""
    }
}

/// Compressor FourCCs that route to `DxvSourceReader` (stsd texture tags of
/// Alley-style outputs, and the DXV version tags).
let dxvSourceFourCCs: Set<String> = ["DXT1", "DXT5", "YCG6", "YG10", "DXDI", "DXD3"]
