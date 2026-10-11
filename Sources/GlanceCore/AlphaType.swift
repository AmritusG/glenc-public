// SPDX-License-Identifier: MIT
//
// v0.18.0 — what a clip's alpha means: the per-clip "Alpha Type" switch
// (Amrit, 2026-10-10: "Switch."), shared by Glance, MaCrate and CueGlance.
//
// A DXV file does not say whether its colour is straight or premultiplied by
// alpha (DXVKit spec DXV_FORMAT.md 8.5: no field in the packet, the sample
// description or the atoms; both kinds of file exist: Resolume Alley, DXVKit
// and GlEnc 1.6 write straight, Adobe Media Encoder premultiplied). Resolume
// Arena lets the user choose per clip with "Alpha Type", default
// Premultiplied; Glance does the same for DXV alpha clips (DXT5, YG10, legacy
// DXT5). Formats that state their convention are read as stated and show the
// switch disabled: HAP alpha is straight (Amrit, 2026-10-10: "Keep straight"),
// as GlEnc writes it and Glance always read it; ProRes 4444 / HEVC alpha are
// AVFoundation's (straight unless the format description says
// premultiplied).
//
// The hint is spec 8.5's pixel metric (ported from GlEnc 1.6.0's
// SourceAlpha): on sample pixels with 8 < alpha < 200 (every 7th pixel), the
// share whose max(R, G, B) exceeds alpha + 24. Premultiplied colour cannot
// exceed its alpha (apart from block error), so a share near 0 "looks
// premultiplied" (dark straight content can look the same: a reading, not
// proof) and a few per cent "looks straight". It never changes the setting.

import Foundation
import CryptoKit
import AVFoundation
import CoreMedia
import DXVKit

/// Arena's names and default.
public enum AlphaType: String, CaseIterable, Codable, Sendable {
    case premultiplied
    case straight

    public static let `default`: AlphaType = .premultiplied

    public var label: String {
        switch self {
        case .premultiplied: return "Premultiplied"
        case .straight: return "Straight"
        }
    }
}

/// Spec 8.5's reading of a clip's colour.
public enum AlphaLook: String, Equatable, Sendable {
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
    /// At or below this share: looks premultiplied (spec: "near 0"; AME /
    /// premultiplied files measure 0.0 – 0.1 %).
    public static let premultipliedAtMost = 0.005
    /// At or above this share: looks straight (spec: "clearly above a few
    /// per cent"; straight files measure 8.6 – 98 %).
    public static let straightAtLeast = 0.03

    /// Counts over one RGBA frame (bytes as decoded, no alpha processing):
    /// semi-transparent samples and those whose max(R, G, B) > alpha + 24.
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

/// What a clip's alpha is, for the Alpha Type control.
public struct AlphaTypeReport: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// No alpha: no control.
        case none
        /// A DXV clip with alpha: the file does not say; the user chooses.
        case choosable
        /// The format states it: the control shows this value, disabled.
        case stated(AlphaType, by: String)
    }
    public let kind: Kind
    /// Spec 8.5 reading of the first and middle frames (nil when not measured).
    public let look: AlphaLook?
    /// Semi-transparent sample pixels, and the share brighter than alpha + 24.
    public let samples: Int
    public let share: Double

    public init(kind: Kind, look: AlphaLook? = nil, samples: Int = 0, share: Double = 0) {
        self.kind = kind; self.look = look; self.samples = samples; self.share = share
    }
}

public enum AlphaTypeProbe {

    /// DXV alpha -> choosable + the hint; HAP alpha -> stated straight;
    /// AVFoundation alpha -> stated by the format description; else none.
    public static func probe(_ url: URL) async -> AlphaTypeReport {
        if let cc = DXVDetector.compressorFourCC(at: url), dxvFourCCs.contains(cc) {
            return (try? probeDXV(url)) ?? AlphaTypeReport(kind: .none)
        }
        if let hap = HAPDetector.compressorFourCCIfHAP(at: url) {
            return ["Hap5", "HapM", "HapA"].contains(hap)
                ? AlphaTypeReport(kind: .stated(.straight, by: "HAP"))
                : AlphaTypeReport(kind: .none)
        }
        return await probeAVFoundation(url)
    }

    /// DXV: alpha variants only (DXT5, YG10, legacy DXT5); the hint on the
    /// first and middle frames.
    public static func probeDXV(_ url: URL) throws -> AlphaTypeReport {
        let movie = try DXVMovie(url: url)
        guard movie.frameCount > 0, movie.hasAlpha else { return AlphaTypeReport(kind: .none) }
        let frame = DXVKit.DXVFrame()
        var samples = 0, exceeding = 0
        for index in Set([0, movie.frameCount / 2]).sorted() {
            try movie.decodeBlocks(at: index, into: frame)
            let rgba = try frame.rgba()
            let c = rgba.withUnsafeBytes { AlphaLookMetric.count(rgba: $0, pixelCount: rgba.count / 4) }
            samples += c.samples; exceeding += c.exceeding
        }
        return AlphaTypeReport(kind: .choosable,
                               look: AlphaLookMetric.classify(samples: samples, exceeding: exceeding),
                               samples: samples,
                               share: samples > 0 ? Double(exceeding) / Double(samples) : 0)
    }

    static func probeAVFoundation(_ url: URL) async -> AlphaTypeReport {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fmt = (try? await track.load(.formatDescriptions))?.first else {
            return AlphaTypeReport(kind: .none)
        }
        let exts = CMFormatDescriptionGetExtensions(fmt) as? [String: Any] ?? [:]
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(fmt))
        let containsAlpha = (exts[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? NSNumber)?.boolValue
            ?? ["ap4h", "ap4x"].contains(codec)
        guard containsAlpha else { return AlphaTypeReport(kind: .none) }
        let name = ["ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ", "hvc1": "HEVC", "hev1": "HEVC"][codec] ?? codec
        let mode = exts[kCMFormatDescriptionExtension_AlphaChannelMode as String] as? String
        return AlphaTypeReport(kind: .stated(
            mode == (kCMFormatDescriptionAlphaChannelMode_PremultipliedAlpha as String) ? .premultiplied : .straight,
            by: name))
    }

    /// A key for remembering a clip's choice: the SHA-256 of its byte size,
    /// frame count, size and first and last DXV packets. A moved or renamed
    /// copy of the same file keeps its choice; a re-encode at the same path
    /// gets a new key (its packets differ), so it never inherits a choice made
    /// for other content. Nil for non-DXV files.
    public static func clipKey(_ url: URL) -> String? {
        guard let movie = try? DXVMovie(url: url), movie.frameCount > 0,
              let first = try? movie.packet(at: 0), let last = try? movie.packet(at: movie.frameCount - 1) else { return nil }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var h = SHA256()
        h.update(data: Data("\(bytes) \(movie.frameCount) \(movie.width)x\(movie.height)".utf8))
        h.update(data: first)
        h.update(data: last)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fourCC(_ v: FourCharCode) -> String {
        String(bytes: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)],
               encoding: .ascii) ?? ""
    }

    static let dxvFourCCs: Set<String> = ["DXT1", "DXT5", "YCG6", "YG10", "DXDI", "DXD3", "DXD4", "DXV3"]
}
