// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation

/// HAP codec FourCC sniffer. The MOV-walking is identical to DXV's
/// (both formats use the same MOV container layout), so we delegate
/// to `DXVDetector.compressorFourCC(at:)` and expose a HAP-flavored
/// recogniser on top. Keep `isHAPFourCC` and the FourCC set in
/// `displayName(for:)` (DXVDetector) in sync — both touch the same
/// codec membership question and drift between them surfaces as
/// "the cell knows it's HAP but the demuxer doesn't, or vice versa."
public enum HAPDetector {

    /// Returns true for any of the HAP codec family FourCCs as stored
    /// in MOV `stsd`. Used by `HAPThumbnail.cgImageOfFirstFrame(at:)`
    /// to fail fast on non-HAP input.
    public static func isHAPFourCC(_ fourCC: String) -> Bool {
        switch fourCC {
        case "Hap1", "Hap5", "HapY", "HapM", "HapA": return true
        default: return false
        }
    }

    /// Convenience wrapper for the common "detect, then route" flow:
    /// reads the first video trak's FourCC and returns it iff the
    /// codec is HAP. `nil` for non-HAP, non-MOV, or parse failure.
    /// Sibling apps (Crate) can use this in place of two calls.
    public static func compressorFourCCIfHAP(at url: URL) -> String? {
        guard let cc = DXVDetector.compressorFourCC(at: url),
              isHAPFourCC(cc)
        else { return nil }
        return cc
    }
}
