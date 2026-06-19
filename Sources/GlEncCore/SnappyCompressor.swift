// SPDX-License-Identifier: BSD-3-Clause
import Foundation

/// v0.9.1 Phase B — Snappy compressor (from-scratch Swift port).
///
/// Output is byte-compatible with any Snappy decompressor — the
/// project's existing decompression dependency
/// (`lovetodream/swift-snappy`, BSD-3 wrapping Google's reference C
/// snappy-c) is the test oracle: every encoded blob in the test
/// suite is decoded back to source and asserted byte-equal.
///
/// Format reference: https://github.com/google/snappy/blob/main/format_description.txt
///
/// Algorithm: LZ77-style hash-table match finder.
///   - 14-bit hash table (16K entries), seeded with `0x1E35A7BD`
///     multiplier per Google's reference.
///   - Min match length 4. Matches < 4 emit as literals.
///   - 16-bit offset window (matches up to 64KB back).
///   - Greedy match emission (no lazy-match deferral).
///
/// Output format (one Snappy frame):
///   1. Varint preamble: uncompressed length, 1–5 bytes LE.
///   2. Token stream:
///      - `00`: literal — `(n - 1) << 2`, where n = literal byte count.
///        Extended lengths use tags 0xF0 / 0xF4 / 0xF8 / 0xFC + 1/2/3/4
///        extra length bytes.
///      - `01`: copy with 11-bit offset and 3-bit length (4..11).
///      - `10`: copy with 16-bit offset and 6-bit length (1..64).
///      - `11`: copy with 32-bit offset (unused here; max-offset stays
///        ≤ 65535 to keep all back-refs in 16-bit form).
public enum SnappyCompressor {

    /// Public entry point. Compresses `input` to a Snappy frame.
    /// Empty input → 1-byte output (varint 0).
    public static func compress(_ input: Data) -> Data {
        var output = Data()
        // Preallocate worst-case: 32 + n + (n / 6). The literal-only
        // path produces at most 1 tag byte per 60-byte chunk (overhead
        // ~1.7%), and we never expand by more than a constant from the
        // varint preamble (≤ 5 bytes for sources ≤ 4GB).
        output.reserveCapacity(input.count + 32 + input.count / 6)

        writeVarint(UInt64(input.count), to: &output)

        if input.isEmpty { return output }
        input.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            compressBlock(base, length: input.count, output: &output)
        }
        return output
    }

    // MARK: - Tunables

    private static let hashBits = 14
    private static let hashTableSize = 1 << hashBits  // 16,384
    /// Max back-reference distance. 16 bits matches the 2-byte copy
    /// form's offset field — keeps the encoder from emitting 4-byte
    /// copy tokens (0x11), which the spec allows but reference
    /// decoders rarely exercise. 64KB also matches the reference C++
    /// compressor's per-block window.
    private static let maxOffset = 1 << 16

    // MARK: - Core compression loop

    private static func compressBlock(
        _ base: UnsafePointer<UInt8>,
        length n: Int,
        output: inout Data
    ) {
        // Hash table tracks the most recent occurrence index for each
        // 4-byte key. -1 = unseen.
        var hashTable = [Int32](repeating: -1, count: hashTableSize)

        var nextEmit = 0  // start of pending literal
        var ip = 0        // current input position

        // The +4 ensures we always have a valid 4-byte key to hash.
        while ip + 4 <= n {
            let key = load32(base, at: ip)
            let h = hashKey(key)
            let candidate = Int(hashTable[h])
            hashTable[h] = Int32(ip)

            // Match conditions:
            //   1. candidate index in-range (not -1)
            //   2. within the 64KB back-reference window
            //   3. 4-byte prefix actually matches (hash collision check)
            if candidate >= 0,
               (ip - candidate) < maxOffset,
               load32(base, at: candidate) == key {
                // Confirmed 4-byte match. Extend forward greedily.
                var matchLen = 4
                while ip + matchLen < n
                      && base[candidate + matchLen] == base[ip + matchLen] {
                    matchLen += 1
                }
                let offset = ip - candidate

                // Flush any pending literal before the copy token.
                if ip > nextEmit {
                    emitLiteral(base, from: nextEmit,
                                length: ip - nextEmit, to: &output)
                }
                emitCopy(length: matchLen, offset: offset, to: &output)

                ip += matchLen
                nextEmit = ip
            } else {
                ip += 1
            }
        }

        // Trailing literal: everything from the last match end to EOF.
        if nextEmit < n {
            emitLiteral(base, from: nextEmit, length: n - nextEmit, to: &output)
        }
    }

    // MARK: - Varint preamble

    /// Snappy preamble is a little-endian varint of the uncompressed
    /// byte count. 1–5 bytes for sources up to 2^32-1.
    private static func writeVarint(_ value: UInt64, to output: inout Data) {
        var v = value
        while v >= 0x80 {
            output.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        output.append(UInt8(v & 0x7F))
    }

    // MARK: - Hash + 32-bit load

    /// Snappy reference uses a multiplicative hash: `(load32 * 0x1E35A7BD) >> (32 - bits)`.
    /// The shifted product's top `bits` of the multiplied 32-bit
    /// value index into the hash table.
    @inline(__always)
    private static func hashKey(_ key: UInt32) -> Int {
        let multiplied = key &* 0x1E35A7BD
        return Int(multiplied >> UInt32(32 - hashBits))
    }

    /// Little-endian 32-bit load. Snappy's hash function operates on
    /// the byte order of the input bytes interpreted as LE — flipping
    /// to BE would still hash deterministically but doesn't match the
    /// reference compressor's behaviour on identical 4-byte sequences.
    @inline(__always)
    private static func load32(_ base: UnsafePointer<UInt8>, at i: Int) -> UInt32 {
        UInt32(base[i])
            | (UInt32(base[i + 1]) << 8)
            | (UInt32(base[i + 2]) << 16)
            | (UInt32(base[i + 3]) << 24)
    }

    // MARK: - Literal token

    /// Emit a literal token. Tag-byte type `00`, with length encoded
    /// as either inline (small literals) or via 1–4 extra length
    /// bytes for larger ones.
    private static func emitLiteral(
        _ base: UnsafePointer<UInt8>,
        from start: Int,
        length: Int,
        to output: inout Data
    ) {
        // Encoded value is `length - 1`.
        let n = length - 1
        if n < 60 {
            // Inline length in the tag byte's top 6 bits.
            output.append(UInt8(n << 2))
        } else if n < 256 {
            output.append(0xF0)  // (60 << 2) | 00
            output.append(UInt8(n))
        } else if n < 65536 {
            output.append(0xF4)  // (61 << 2) | 00
            output.append(UInt8(n & 0xFF))
            output.append(UInt8((n >> 8) & 0xFF))
        } else if n < 16_777_216 {
            output.append(0xF8)  // (62 << 2) | 00
            output.append(UInt8(n & 0xFF))
            output.append(UInt8((n >> 8) & 0xFF))
            output.append(UInt8((n >> 16) & 0xFF))
        } else {
            output.append(0xFC)  // (63 << 2) | 00
            output.append(UInt8(n & 0xFF))
            output.append(UInt8((n >> 8) & 0xFF))
            output.append(UInt8((n >> 16) & 0xFF))
            output.append(UInt8((n >> 24) & 0xFF))
        }
        output.append(UnsafeBufferPointer(start: base.advanced(by: start),
                                          count: length))
    }

    // MARK: - Copy token

    /// Emit one or more copy tokens covering a back-reference of
    /// `length` bytes at `offset` distance. Each token caps at length
    /// 64 (2-byte form) or 11 (1-byte form); long matches chunk.
    ///
    /// Token selection per chunk:
    ///   - Length in [4..11] AND offset < 2048 → 1-byte form (2 bytes total).
    ///   - Otherwise → 2-byte form (3 bytes total), length capped at 64.
    ///
    /// Chunking reservation (v0.9.1 Phase H.3): the 1-byte form
    /// encodes `length - 4` in 3 bits, so its chunk must be ≥ 4.
    /// When a long match `length mod 64 ∈ {1, 2, 3}` with `offset <
    /// 2048`, naive chunking at 64-byte tokens leaves 1..3 bytes for
    /// a final iteration that drops into the 1-byte branch — and
    /// `chunk - 4` underflows to -3..-1, trapping
    /// `UInt8(negativeInt)`. To avoid that, when the 2-byte form is
    /// about to leave 1..3 bytes AND the offset is in the 1-byte
    /// form's range, emit a 60-byte chunk first (leaves 5..7 for
    /// the next iter — safe for the 1-byte form). Matches Google's
    /// snappy.cc `EmitCopy` reservation strategy.
    private static func emitCopy(length: Int, offset: Int, to output: inout Data) {
        precondition(length >= 4, "copy tokens require length ≥ 4")
        precondition(offset >= 1, "copy offset must be positive")
        precondition(offset < maxOffset, "copy offset exceeds 16-bit window")

        var remaining = length
        while remaining > 0 {
            if remaining >= 12 || offset >= 2048 {
                // 2-byte form: type 10, length 1..64, offset 0..65535.
                // If naive `min(remaining, 64)` would leave 1..3
                // bytes AND the next iter would land in the 1-byte
                // form (offset < 2048), chunk at 60 instead so the
                // remainder is 5..7 — safe for `chunk - 4` ≥ 0.
                let chunk: Int
                if offset < 2048 && remaining > 64 && remaining < 68 {
                    chunk = 60
                } else {
                    chunk = min(remaining, 64)
                }
                let tag = UInt8(((chunk - 1) << 2) | 0b10)
                output.append(tag)
                output.append(UInt8(offset & 0xFF))
                output.append(UInt8((offset >> 8) & 0xFF))
                remaining -= chunk
            } else {
                // 1-byte form: type 01, length 4..11, offset 0..2047.
                // Tag layout: [offset>>8 : 3 bits][len-4 : 3 bits][01 : 2 bits]
                // Invariant: `remaining` is 4..11 here (≥ 4 by
                // construction — the 2-byte branch above never leaves
                // < 4 when offset < 2048; ≤ 11 because the outer
                // `if remaining >= 12` would have routed to 2-byte).
                let chunk = min(remaining, 11)
                let lenBits = chunk - 4               // 0..7
                let highOffset = (offset >> 8) & 0x07  // 0..7
                let tag = UInt8(0b01
                                | (lenBits << 2)
                                | (highOffset << 5))
                output.append(tag)
                output.append(UInt8(offset & 0xFF))
                remaining -= chunk
            }
        }
    }
}
