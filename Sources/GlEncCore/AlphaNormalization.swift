// SPDX-License-Identifier: MIT
/*
 * AlphaNormalization — v0.9.2 Phase B.
 *
 * Source-alpha normalization helper, extracted from DXT5Encoder's
 * Phase B Pass B logic per DECISIONS-2026-05-10-PassB.md. Shared by
 * `DXT5Encoder` (DXV3 DXT5 path + Hap5 path), `HapABlockPacker`
 * (v0.9.2), and `HapMEncoder` (v0.9.3).
 *
 * Pass B rule (verified empirically against AME + Alley + GlanceCore):
 * BC1 stores STRAIGHT RGB; BC4 alpha plane stores STRAIGHT alpha.
 * Source `CGImageAlphaInfo` is inspected once per frame to choose:
 *
 *   .premultipliedFirst / .premultipliedLast
 *       Un-premultiply: R' = round(R * 255 / α) when α > 0; α=0 → RGB=0.
 *       Same for G, B.
 *   .first / .last
 *       Straight RGB and straight alpha as-is.
 *   .noneSkipFirst / .noneSkipLast / .none
 *       Source has no usable alpha. Force α = 255.
 *   .alphaOnly
 *       Degenerate — fail with a clear error.
 *
 * The per-pixel un-premultiply formula uses integer arithmetic with a
 * +α/2 rounding bias, mirroring the previous inline DXT5Encoder
 * implementation byte-for-byte. DXT5 byte-identity must hold across
 * the Phase B extraction.
 */

import Foundation
import CoreGraphics

public enum AlphaNormalization: Sendable {
    /// Source has no usable alpha. Output α is forced to 255.
    case forceOpaque
    /// Source alpha is already straight; pass through unchanged.
    case straightThrough
    /// Source RGB is premultiplied; divide back out per pixel.
    case unpremultiply

    public enum Error: Swift.Error, CustomStringConvertible {
        /// `.alphaOnly` source frames have no RGB to encode. Surfaced
        /// as an unrecoverable error by callers.
        case unsupportedAlphaInfo(CGImageAlphaInfo)
        public var description: String {
            switch self {
            case .unsupportedAlphaInfo(let info):
                return "AlphaNormalization: alphaOnly source frames are not supported (got \(info.rawValue))"
            }
        }
    }

    /// True iff this mode represents a source that carries usable
    /// alpha — i.e. the encoder will write meaningful α bytes.
    /// Callers that reject opaque sources (HapA: v0.9.2 Q2 decision)
    /// preflight via this property before invoking the block packer.
    public var sourceHasAlpha: Bool {
        switch self {
        case .forceOpaque:                       return false
        case .straightThrough, .unpremultiply:   return true
        }
    }

    /// Decide normalization from a `CGImageAlphaInfo`. Mirrors the
    /// previous private `DXT5Encoder.alphaNormalization(for:)` switch
    /// byte-for-byte (and shares its `@unknown default` defensive
    /// fall-through to `.straightThrough`).
    public static func mode(for info: CGImageAlphaInfo) throws -> AlphaNormalization {
        switch info {
        case .premultipliedFirst, .premultipliedLast:
            return .unpremultiply
        case .first, .last:
            return .straightThrough
        case .noneSkipFirst, .noneSkipLast, .none:
            return .forceOpaque
        case .alphaOnly:
            throw Error.unsupportedAlphaInfo(info)
        @unknown default:
            return .straightThrough
        }
    }

    /// Apply this normalization to one RGBA pixel. Returns the output
    /// (R, G, B, A) that should be written into the destination buffer.
    ///
    /// For `.unpremultiply`, the integer math + rounding bias matches
    /// `DXT5Encoder.copyBGRAToPaddedRGBA`'s prior inline implementation
    /// byte-for-byte. `@inline(__always)` ensures the per-pixel hot
    /// loop pays no function-call overhead vs the prior inline switch.
    @inline(__always)
    public func apply(r: UInt8, g: UInt8, b: UInt8, a: UInt8)
            -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        switch self {
        case .forceOpaque:
            return (r, g, b, 255)
        case .straightThrough:
            return (r, g, b, a)
        case .unpremultiply:
            if a == 0 {
                return (0, 0, 0, 0)
            }
            let aInt = Int(a)
            let half = aInt / 2
            let r2 = UInt8(min(255, (Int(r) * 255 + half) / aInt))
            let g2 = UInt8(min(255, (Int(g) * 255 + half) / aInt))
            let b2 = UInt8(min(255, (Int(b) * 255 + half) / aInt))
            return (r2, g2, b2, a)
        }
    }
}
