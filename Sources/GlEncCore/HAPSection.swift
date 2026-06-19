// SPDX-License-Identifier: MIT
/*
 * HAPSection — shared HAP section-header emitter.
 *
 * v0.9.1 Phase E. Hap1Encoder (Phase D) and Hap5Encoder (Phase E)
 * both need to wrap a Snappy-compressed payload in a HAP section
 * header. The bytes are identical aside from the section-type byte:
 *
 *   0xBB  Snappy + DXT1     (Hap1)
 *   0xBE  Snappy + DXT5     (Hap5)
 *   0xBF  Snappy + YCoCg-DXT5 (HapY, Phase F)
 *
 * Layout (Vidvox HAP spec):
 *
 *   short form (payload < 16 MB):
 *       bytes 0..2: payload length LSB→MSB (24-bit LE)
 *       byte 3:     section type
 *       bytes 4..:  payload
 *
 *   extended form (payload ≥ 16 MB):
 *       bytes 0..2: zero (signals extended form)
 *       byte 3:     section type
 *       bytes 4..7: payload length LSB→MSB (32-bit LE)
 *       bytes 8..:  payload
 *
 * The header is always little-endian regardless of platform.
 */

import Foundation

internal enum HAPSection {

    enum HAPSectionError: Error, CustomStringConvertible {
        case payloadExceedsMaxSize(size: Int)
        var description: String {
            switch self {
            case .payloadExceedsMaxSize(let s):
                return "HAPSection: payload \(s) bytes exceeds 4 GB (max for extended-form section header)"
            }
        }
    }

    /// 24-bit upper bound; payloads at or above this size require the
    /// 8-byte extended-form header.
    static let shortFormMax = 1 << 24  // 16,777,216

    /// Wrap `payload` in a HAP section header carrying `type`. Picks
    /// short or extended form automatically. Throws if `payload.count`
    /// exceeds the 32-bit extended-form length field (>4 GB).
    static func make(payload: Data, type: UInt8) throws -> Data {
        let size = payload.count
        if size < shortFormMax {
            var section = Data(capacity: 4 + size)
            section.append(UInt8( size        & 0xFF))
            section.append(UInt8((size >>  8) & 0xFF))
            section.append(UInt8((size >> 16) & 0xFF))
            section.append(type)
            section.append(payload)
            return section
        }
        guard size <= Int(UInt32.max) else {
            throw HAPSectionError.payloadExceedsMaxSize(size: size)
        }
        var section = Data(capacity: 8 + size)
        section.append(0)
        section.append(0)
        section.append(0)
        section.append(type)
        let s32 = UInt32(size)
        section.append(UInt8( s32        & 0xFF))
        section.append(UInt8((s32 >>  8) & 0xFF))
        section.append(UInt8((s32 >> 16) & 0xFF))
        section.append(UInt8((s32 >> 24) & 0xFF))
        section.append(payload)
        return section
    }
}
