// SPDX-License-Identifier: MIT
import Foundation

/// The codec variants GlEnc can emit. Single source of truth across
/// the app and the encoder backend.
///
/// Per DECISIONS-2026-05-09.md and HANDOVER.md §3:
///   - dxt1 / dxt5: Normal-quality DXT-style block compression. DXT5
///     adds an 8-byte alpha block per 4×4 tile; per the FFmpeg /
///     Resolume convention DXT5's RGB is treated as premultiplied
///     (DXT4 semantics).
///   - ycg6 / yg10: HQ — non-reversible YCoCg with chroma subsampling
///     and BC4-compressed planes plus an opcode-stream prelude.
///     yg10 is ycg6 + a fourth BC4 plane for alpha.
///   - hap1 / hap5 / hapY (v0.9.1): Vidvox HAP variants — BC1 / BC3 /
///     scaled-YCoCg-BC3 textures + Snappy compression + HAP section
///     header per Vidvox spec. MOV stream-level FourCC matches the
///     Hap1 / Hap5 / HapY name (NOT DXD3 — these are HAP files,
///     decoded by GlanceCore's HAPPacketDecoder, not DXVPacketDecoder).
///   - hapA (v0.9.2): HAP Alpha-only — RGTC1/BC4 single-channel alpha
///     texture + Snappy + section type 0xB1. No RGB. MOV FourCC "HapA".
///   - hapM (v0.9.3): HAP Q + Alpha — outer 0x0D section wrapping an
///     inner HapY (color, 0xBF) + inner HapA (alpha, 0xB1). MOV
///     FourCC "HapM". The Resolume-loadable HAP+alpha variant
///     standalone HapA can't satisfy (Resolume doesn't import
///     standalone HapA as a clip codec — v0.9.2 Phase F finding).
///
/// The four DXV3 variants share the MOV stream-level FourCC `DXD3`;
/// the per-frame 4-byte Tag (little-endian on disk) disambiguates.
/// HAP variants use distinct stream-level FourCCs and have no
/// per-frame DXV3 tag (`frameTagBytes` returns nil).
public enum DXVFormat: String, CaseIterable, Hashable, Codable, Sendable {
    case dxt1
    case dxt5
    case ycg6
    case yg10
    case hap1
    case hap5
    case hapY = "hapy"
    case hapA = "hapa"
    case hapM = "hapm"

    /// DXV3 internal sub-tier. Only meaningful for the DXV3 family;
    /// HAP variants are queried by `family` instead.
    public enum Tier: Sendable {
        case normal
        case hq
    }

    /// Codec family. Drives encoder dispatch (DXV3 family →
    /// LZ-compressed DXV3 packets; HAP family → Snappy-compressed
    /// HAP sections) and writer FourCC.
    public enum Family: Sendable {
        case dxv3
        case hap
    }

    public var family: Family {
        switch self {
        case .dxt1, .dxt5, .ycg6, .yg10:               return .dxv3
        case .hap1, .hap5, .hapY, .hapA, .hapM:        return .hap
        }
    }

    /// DXV3 internal tier. For HAP variants, returns `.normal` as a
    /// neutral default (HAP doesn't use this axis; UI uses
    /// `qualityTier` / `family` instead). HapY/HapM map to `.hq`
    /// because HAP Q (the HQ scaled-YCoCg form) is their UI tier.
    public var tier: Tier {
        switch self {
        case .dxt1, .dxt5, .hap1, .hap5, .hapA: return .normal
        case .ycg6, .yg10, .hapY, .hapM:        return .hq
        }
    }

    /// Whether this variant carries an alpha channel.
    public var hasAlpha: Bool {
        switch self {
        case .dxt1, .ycg6, .hap1, .hapY:               return false
        case .dxt5, .yg10, .hap5, .hapA, .hapM:        return true
        }
    }

    /// Short user-visible label.
    public var label: String {
        switch self {
        case .dxt1: return "DXT1"
        case .dxt5: return "DXT5"
        case .ycg6: return "YCG6"
        case .yg10: return "YG10"
        case .hap1: return "Hap1"
        case .hap5: return "Hap5"
        case .hapY: return "HapY"
        case .hapA: return "HapA"
        case .hapM: return "HapM"
        }
    }

    /// Longer label including the tier and alpha hint, suitable for
    /// menu rows and documentation.
    public var verboseLabel: String {
        switch self {
        case .dxt1: return "DXT1 — Normal, no alpha"
        case .dxt5: return "DXT5 — Normal + alpha (premultiplied)"
        case .ycg6: return "YCG6 — HQ, no alpha"
        case .yg10: return "YG10 — HQ + alpha"
        case .hap1: return "Hap1 — HAP, no alpha"
        case .hap5: return "Hap5 — HAP + alpha"
        case .hapY: return "HapY — HAP Q (Scaled YCoCg)"
        case .hapA: return "HapA — HAP, alpha only"
        case .hapM: return "HapM — HAP Q + alpha"
        }
    }

    /// The per-frame Tag bytes as written to disk (little-endian) for
    /// DXV3 variants. HAP variants return nil — HAP has no per-frame
    /// DXV3 tag; section type bytes live inside HAP section headers
    /// (see HAPSection.swift).
    public var frameTagBytes: [UInt8]? {
        switch self {
        case .dxt1: return [0x31, 0x54, 0x58, 0x44] // "1TXD" on disk = "DXT1" LE
        case .dxt5: return [0x35, 0x54, 0x58, 0x44] // "5TXD"
        case .ycg6: return [0x36, 0x47, 0x43, 0x59] // "6GCY"
        case .yg10: return [0x30, 0x31, 0x47, 0x59] // "01GY"
        case .hap1, .hap5, .hapY, .hapA, .hapM: return nil
        }
    }

    /// MOV stream-level codec FourCC. DXV3 variants share `DXD3`;
    /// HAP variants use the per-codec FourCC matching their name.
    /// Drives `VariantMOVWriter`'s stsd sample entry.
    public var streamFourCC: String {
        switch self {
        case .dxt1, .dxt5, .ycg6, .yg10: return "DXD3"
        case .hap1: return "Hap1"
        case .hap5: return "Hap5"
        case .hapY: return "HapY"
        case .hapA: return "HapA"
        case .hapM: return "HapM"
        }
    }
}
