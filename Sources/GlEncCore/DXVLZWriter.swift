// SPDX-License-Identifier: LGPL-2.1-or-later
/*
 * DXV3 LZ-pass writer (DXT1 + DXT5 variants).
 *
 * `compressDXT1` is a Swift port of FFmpeg's libavcodec/dxvenc.c —
 * specifically `dxv_compress_dxt1` and the `PUSH_OP` macro. Three
 * hashtables (color, lut, combo) feed an LZ back-reference scheme; ops
 * are 2-bit symbols packed 16-per-uint32 into the output stream. Phase
 * 2A target: byte-identity with `ffmpeg -c:v dxv -format dxt1` per
 * DECISIONS-2026-05-09-PassA.md. The DXT1 path is byte-identity-locked
 * and is not modified by Phase 3A.
 *
 * `compressDXT5` is original Phase 3A work guided by `dxv.c`'s
 * `dxv_decompress_dxt5` decoder. Each 16-byte block has two halves:
 *
 *   - First half (8-byte BC4 alpha block, 2 dwords): emitted via the
 *     outer 2-bit op switch. Phase 3A "Strategy A" implements only op2
 *     (idx-copy from ≥ 2 blocks back) and op3 (literal). op0 (long-copy
 *     run) and op1 (alpha-half run-init) are DXT5-specific extensions
 *     beyond DXT1's repertoire — skipped here per priming, can land in a
 *     later phase if file size proves an issue. The "alpha hashtable"
 *     keys 8-byte alpha-block bytes against the dword position they
 *     appeared at; lookups produce a back-reference distance encoded as
 *     `(idx - 8) / 4` little-endian-16 trailing the 2-bit op.
 *
 *   - Second half (8-byte BC1 color block, 2 dwords): emitted via
 *     CHECKPOINT(4)-style PUSH_OP — same combo / color / lut logic as
 *     DXT1, just with x=4 (one block = 4 dwords) so combo idx=4 means
 *     "this block's color-half matches the previous block's
 *     color-half." `pushOp` already takes `x` as a parameter so it's
 *     reused unchanged.
 *
 * The outer-switch ops and CHECKPOINT(4) ops share the same 2-bit op
 * dword (rolling state machine) — `pushOp` and `pushOuterOp` both
 * mutate `state` and `dwordOffset` cooperatively.
 *
 * Original C (DXT1 reference): Copyright (C) 2024 Emma Worley
 * <emma@emma.gg>, FFmpeg. LGPL 2.1+ — Swift port preserves the same
 * license. Decoder reference (DXT5 LZ semantics): Copyright (C) 2015
 * Vittorio Giovara, 2018 Paul B Mahol; LGPL 2.1+.
 *
 * Swift port + Phase 3A DXT5 extension: GlEnc, 2026. LGPL 2.1+.
 */

import Foundation

public final class DXVLZWriter {
    /// LOOKBACK_WORDS for DXT1 (x=2). The hashtables soft-evict any entry
    /// whose stored position is older than `pos - LOOKBACK_WORDS`. Beyond
    /// that distance, the 2-bit op encoding can't represent the
    /// back-reference (max idx = (0xFFFF + 0x102) * x = the encoding
    /// ceiling for op=3), so the hashtable keeps only the freshly-
    /// reachable entries. dxvenc.c locks this at 0x20202 = max_idx for
    /// x=2.
    public static let lookbackWords: UInt32 = 0x20202

    /// LOOKBACK_WORDS for DXT5 (x=4). max_idx for x=4 is 0x40404. We
    /// also need this to be a multiple of 4 (= the block-stride in dword
    /// units) so the FFmpeg-style "evict by reading the byte value at
    /// pos-LOOKBACK" logic lands on aligned positions every time.
    /// 0x40404 = 4 × 0x10101 satisfies both.
    public static let lookbackWordsDXT5: UInt32 = 0x40404

    private var output: [UInt8] = []
    /// Byte offset within `output` of the current op-packing dword. Valid only
    /// when `state < 16`; while `state == 16` we'll allocate a fresh dword on
    /// the next pushOp call.
    private var dwordOffset: Int = -1
    /// Number of 2-bit ops already packed into the current dword (0..16).
    private var state: Int = 16

    private var colorHT: [UInt32: UInt32] = [:]
    private var lutHT:   [UInt32: UInt32] = [:]
    private var comboHT: [UInt64: UInt32] = [:]
    /// DXT5-only: keys 8-byte alpha-block bytes (BC4 output, 2 dwords)
    /// against the dword position they were observed at. Lookups during
    /// `compressDXT5` produce back-reference distances ≥ 8 dwords (= 2+
    /// blocks back) for outer-op 2.
    private var alphaHT: [UInt64: UInt32] = [:]

    public init() {}

    /// Compress a packed BC1 block buffer (8 bytes per block) into a DXV3 LZ
    /// stream. `count` must be a multiple of 4 (dword-aligned) and ≥ 8.
    /// Returns the LZ-compressed payload bytes (no DXV3 header — caller
    /// prepends that).
    public func compressDXT1(tex: UnsafePointer<UInt8>, count: Int) -> Data {
        precondition(count >= 8, "DXT1 LZ writer needs at least one block (8 bytes)")
        precondition(count % 4 == 0, "DXT1 LZ writer requires dword-aligned input")
        let texDwords = count / 4
        precondition(texDwords >= 2)

        // Reset per-frame state.
        output.removeAll(keepingCapacity: true)
        // Upper bound from dxvenc.c: tex_size + ceil((tex_size-8)/128) * 12.
        let upperBound = count + ((count - 8 + 127) / 128) * 12 + 16
        output.reserveCapacity(upperBound)
        colorHT.removeAll(keepingCapacity: true)
        lutHT.removeAll(keepingCapacity: true)
        comboHT.removeAll(keepingCapacity: true)
        state = 16
        dwordOffset = -1

        var pos: UInt32 = 0

        // Initial seed (mirrors dxvenc.c lines 109-116):
        //   - combo_ht set at pos=0 (key = bytes 0..7)
        //   - first dword written raw to output
        //   - color_ht set at pos=0 (key = bytes 0..3)
        //   - pos++
        //   - second dword written raw to output
        //   - lut_ht set at pos=1 (key = bytes 4..7)
        //   - pos++
        let combo0 = readUInt64LE(tex, byteOffset: 0)
        comboHT[combo0] = pos
        let dw0 = readUInt32LE(tex, byteOffset: 0)
        appendUInt32LE(dw0)
        colorHT[dw0] = pos
        pos &+= 1
        let dw1 = readUInt32LE(tex, byteOffset: 4)
        appendUInt32LE(dw1)
        lutHT[dw1] = pos
        pos &+= 1

        // Main loop. Each iteration consumes 2 dwords (color + lut) and
        // emits 1 combo op (always) and 0 or 2 color/lut ops + raw dwords.
        while Int(pos) + 2 <= texDwords {
            let posByteOff = Int(pos) * 4

            // ---- Combo (covers the 8 bytes at pos*4) ----
            let comboKey = readUInt64LE(tex, byteOffset: posByteOff)
            let comboPrev = comboHT[comboKey]
            let comboIdx: UInt32 = (comboPrev != nil) ? (pos - comboPrev!) : 0
            pushOp(idx: comboIdx, x: 2)

            if pos >= DXVLZWriter.lookbackWords {
                let oldPos = pos - DXVLZWriter.lookbackWords
                let oldKey = readUInt64LE(tex, byteOffset: Int(oldPos) * 4)
                if let stored = comboHT[oldKey], stored <= oldPos {
                    comboHT.removeValue(forKey: oldKey)
                }
            }
            comboHT[comboKey] = pos

            // ---- Color dword ----
            let colorKey = readUInt32LE(tex, byteOffset: posByteOff)
            if comboIdx == 0 {
                let colorPrev = colorHT[colorKey]
                let colorIdx: UInt32 = (colorPrev != nil) ? (pos - colorPrev!) : 0
                pushOp(idx: colorIdx, x: 2)
                if colorIdx == 0 {
                    appendUInt32LE(colorKey)
                }
            }
            if pos >= DXVLZWriter.lookbackWords {
                let oldPos = pos - DXVLZWriter.lookbackWords
                let oldKey = readUInt32LE(tex, byteOffset: Int(oldPos) * 4)
                if let stored = colorHT[oldKey], stored <= oldPos {
                    colorHT.removeValue(forKey: oldKey)
                }
            }
            colorHT[colorKey] = pos
            pos &+= 1

            // ---- Lut dword (the next dword after the color one) ----
            let lutByteOff = Int(pos) * 4
            let lutKey = readUInt32LE(tex, byteOffset: lutByteOff)
            if comboIdx == 0 {
                let lutPrev = lutHT[lutKey]
                let lutIdx: UInt32 = (lutPrev != nil) ? (pos - lutPrev!) : 0
                pushOp(idx: lutIdx, x: 2)
                if lutIdx == 0 {
                    appendUInt32LE(lutKey)
                }
            }
            if pos >= DXVLZWriter.lookbackWords {
                let oldPos = pos - DXVLZWriter.lookbackWords
                let oldKey = readUInt32LE(tex, byteOffset: Int(oldPos) * 4)
                if let stored = lutHT[oldKey], stored <= oldPos {
                    lutHT.removeValue(forKey: oldKey)
                }
            }
            lutHT[lutKey] = pos
            pos &+= 1
        }

        return Data(output)
    }

    /// Compress a packed BC3 (DXT5) block buffer (16 bytes per block) into
    /// a DXV3 LZ stream. `count` must be a multiple of 16 and ≥ 16.
    /// Returns the LZ-compressed payload bytes (no DXV3 header — caller
    /// prepends that).
    ///
    /// Strategy A: outer-switch op2 (idx-copy ≥ 2 blocks back) and op3
    /// (literal) only. Color half uses the same combo / color / lut
    /// scheme as DXT1, with x=4.
    public func compressDXT5(tex: UnsafePointer<UInt8>, count: Int) -> Data {
        precondition(count >= 16, "DXT5 LZ writer needs at least one block (16 bytes)")
        precondition(count % 16 == 0, "DXT5 LZ writer requires 16-byte-aligned input")
        let texDwords = count / 4
        precondition(texDwords >= 4)

        // Reset per-frame state.
        output.removeAll(keepingCapacity: true)
        // Generous upper bound. Worst case per block (no LZ matches): ~17
        // bytes payload + a per-16-block opdword = ~18 bytes/block. We
        // budget 1.25× the texture size + 32-byte slack.
        let upperBound = count + count / 4 + 32
        output.reserveCapacity(upperBound)
        colorHT.removeAll(keepingCapacity: true)
        lutHT.removeAll(keepingCapacity: true)
        comboHT.removeAll(keepingCapacity: true)
        alphaHT.removeAll(keepingCapacity: true)
        state = 16
        dwordOffset = -1

        // Seed: write the first block's 4 dwords raw (16 bytes).
        for i in 0..<4 {
            appendUInt32LE(readUInt32LE(tex, byteOffset: i * 4))
        }
        // Seed hashtables at block 0:
        //   alphaHT @ pos=0 (alpha-half key = bytes 0..7)
        //   comboHT @ pos=2 (color-half key = bytes 8..15)
        //   colorHT @ pos=2, lutHT @ pos=3
        alphaHT[readUInt64LE(tex, byteOffset: 0)] = 0
        comboHT[readUInt64LE(tex, byteOffset: 8)] = 2
        colorHT[readUInt32LE(tex, byteOffset: 8)] = 2
        lutHT[readUInt32LE(tex, byteOffset: 12)] = 3

        var pos: UInt32 = 4

        while Int(pos) + 2 <= texDwords {
            // ============ First half: alpha at pos, pos+1 (8 bytes) ============
            // Phase 3A.5: try outer-op 1 (run-init) first. The decoder's
            // run mode auto-emits "alpha from pos-4" for byte+1 successive
            // iterations — which is exactly the "this alpha matches the
            // immediately previous block's alpha" case Strategy A could
            // not reach (op-2 min distance is 2 blocks back). Look ahead
            // to find the longest run of consecutive identical alpha
            // halves starting here, emit one op-1, then process each
            // block's color half normally.
            let alphaByteOff = Int(pos) * 4
            let alphaKey = readUInt64LE(tex, byteOffset: alphaByteOff)
            // Block N-1's alpha is at dword pos-4 (always exists since
            // pos starts at 4 after the seed).
            let prevAlphaKey = readUInt64LE(tex, byteOffset: Int(pos - 4) * 4)

            if alphaKey == prevAlphaKey {
                // Look ahead for run length (count of additional blocks
                // whose alpha also matches). The run includes the current
                // block, so runBlocks is at least 1.
                var runBlocks: UInt32 = 1
                var scanPos = pos + 4
                while Int(scanPos) + 2 <= texDwords {
                    let candKey = readUInt64LE(tex, byteOffset: Int(scanPos) * 4)
                    if candKey != alphaKey { break }
                    runBlocks += 1
                    scanPos += 4
                }
                // Emit op-1 + run-count byte (with le16 extension if needed).
                pushOuterOp(op: 1)
                emitRunCount(runBlocks - 1)

                // For each block in the run, the alpha half is auto-emitted
                // by the decoder's run mode (no encoder action). Maintain
                // alphaHT (for future op-2 reach) and process the color
                // half via the usual combo / color / lut path.
                for _ in 0..<runBlocks {
                    evictAlphaHTIfStale(tex: tex, pos: pos)
                    alphaHT[alphaKey] = pos
                    pos &+= 2  // alpha half: decoder fills from pos-4
                    processColorHalf(tex: tex, pos: &pos)
                }
            } else {
                // Strategy A flow: outer op 2 (back-ref ≥ 2 blocks) or op 3
                // (literal). op-1 isn't usable here because the "immediate
                // previous" alpha doesn't match.
                if let prev = alphaHT[alphaKey], pos > prev, (pos - prev) >= 8,
                   (pos - prev - 8) % 4 == 0 {
                    let alphaIdx = pos - prev
                    let le16Val = (alphaIdx - 8) / 4
                    if le16Val <= 0xFFFF {
                        pushOuterOp(op: 2)
                        appendUInt16LE(UInt16(le16Val))
                    } else {
                        // Distance overflows the 16-bit field — fall to
                        // literal. Shouldn't happen given LOOKBACK_WORDS
                        // eviction, but guard anyway.
                        pushOuterOp(op: 3)
                        appendUInt32LE(readUInt32LE(tex, byteOffset: alphaByteOff))
                        appendUInt32LE(readUInt32LE(tex, byteOffset: alphaByteOff + 4))
                    }
                } else {
                    pushOuterOp(op: 3)
                    appendUInt32LE(readUInt32LE(tex, byteOffset: alphaByteOff))
                    appendUInt32LE(readUInt32LE(tex, byteOffset: alphaByteOff + 4))
                }
                evictAlphaHTIfStale(tex: tex, pos: pos)
                alphaHT[alphaKey] = pos
                pos &+= 2

                processColorHalf(tex: tex, pos: &pos)
            }
        }

        return Data(output)
    }

    /// CHECKPOINT(4)-style color-half emit: combo over the 8-byte color
    /// block; if combo missed, two separate dword ops (color + lut) with
    /// possible 4-byte literals. Identical to the inlined Phase 3A logic;
    /// extracted so the run-init path can share it.
    private func processColorHalf(tex: UnsafePointer<UInt8>, pos: inout UInt32) {
        let colorByteOff = Int(pos) * 4
        let comboKey = readUInt64LE(tex, byteOffset: colorByteOff)
        let comboPrev = comboHT[comboKey]
        let comboIdx: UInt32 = (comboPrev != nil) ? (pos - comboPrev!) : 0
        pushOp(idx: comboIdx, x: 4)
        if pos >= DXVLZWriter.lookbackWordsDXT5 {
            let oldPos = pos - DXVLZWriter.lookbackWordsDXT5
            let oldKey = readUInt64LE(tex, byteOffset: Int(oldPos) * 4)
            if let stored = comboHT[oldKey], stored <= oldPos {
                comboHT.removeValue(forKey: oldKey)
            }
        }
        comboHT[comboKey] = pos

        let colorKey = readUInt32LE(tex, byteOffset: colorByteOff)
        if comboIdx == 0 {
            let colorPrev = colorHT[colorKey]
            let colorIdx: UInt32 = (colorPrev != nil) ? (pos - colorPrev!) : 0
            pushOp(idx: colorIdx, x: 4)
            if colorIdx == 0 {
                appendUInt32LE(colorKey)
            }
        }
        if pos >= DXVLZWriter.lookbackWordsDXT5 {
            let oldPos = pos - DXVLZWriter.lookbackWordsDXT5
            let oldKey = readUInt32LE(tex, byteOffset: Int(oldPos) * 4)
            if let stored = colorHT[oldKey], stored <= oldPos {
                colorHT.removeValue(forKey: oldKey)
            }
        }
        colorHT[colorKey] = pos
        pos &+= 1

        let lutByteOff = Int(pos) * 4
        let lutKey = readUInt32LE(tex, byteOffset: lutByteOff)
        if comboIdx == 0 {
            let lutPrev = lutHT[lutKey]
            let lutIdx: UInt32 = (lutPrev != nil) ? (pos - lutPrev!) : 0
            pushOp(idx: lutIdx, x: 4)
            if lutIdx == 0 {
                appendUInt32LE(lutKey)
            }
        }
        if pos >= DXVLZWriter.lookbackWordsDXT5 {
            let oldPos = pos - DXVLZWriter.lookbackWordsDXT5
            let oldKey = readUInt32LE(tex, byteOffset: Int(oldPos) * 4)
            if let stored = lutHT[oldKey], stored <= oldPos {
                lutHT.removeValue(forKey: oldKey)
            }
        }
        lutHT[lutKey] = pos
        pos &+= 1
    }

    /// Eviction for the alpha hashtable, mirroring the per-step logic
    /// inlined in Phase 3A. Keeps alphaHT entries within
    /// LOOKBACK_WORDS_DXT5 of the current pos so that future op-2
    /// references stay representable.
    @inline(__always)
    private func evictAlphaHTIfStale(tex: UnsafePointer<UInt8>, pos: UInt32) {
        if pos >= DXVLZWriter.lookbackWordsDXT5 {
            let oldPos = pos - DXVLZWriter.lookbackWordsDXT5
            let oldKey = readUInt64LE(tex, byteOffset: Int(oldPos) * 4)
            if let stored = alphaHT[oldKey], stored <= oldPos {
                alphaHT.removeValue(forKey: oldKey)
            }
        }
    }

    /// Emit a run-length value for outer op-1, matching dxv.c's decoder
    /// shape: `byte(0..254)` for runs ≤ 254; `byte(0xFF) + le16(probe)*`
    /// where intermediate probes are 0xFFFF (continuation) and the final
    /// probe is < 0xFFFF (exit signal). The decoder accumulates run = 255
    /// + Σ probes when extension fires.
    private func emitRunCount(_ run: UInt32) {
        if run < 255 {
            output.append(UInt8(run))
            return
        }
        output.append(0xFF)
        var remaining = run - 255
        while remaining >= 0xFFFF {
            appendUInt16LE(0xFFFF)
            remaining -= 0xFFFF
        }
        appendUInt16LE(UInt16(remaining))
    }

    /// Outer-switch 2-bit op for DXT5's first-half alpha encoding. Shares
    /// the rolling op-packing dword with `pushOp` — both functions read
    /// and write `state` / `dwordOffset` cooperatively. Trailing payload
    /// bytes (le16 for op=2, 8 bytes for op=3) are appended by the
    /// caller after this returns.
    @inline(__always)
    private func pushOuterOp(op: UInt32) {
        if state == 16 {
            let off = output.count
            output.append(0)
            output.append(0)
            output.append(0)
            output.append(0)
            dwordOffset = off
            state = 0
        }
        let off = dwordOffset
        let cur = UInt32(output[off]) |
                 (UInt32(output[off + 1]) << 8) |
                 (UInt32(output[off + 2]) << 16) |
                 (UInt32(output[off + 3]) << 24)
        let newVal = cur | (op << (state * 2))
        output[off]     = UInt8(newVal & 0xFF)
        output[off + 1] = UInt8((newVal >> 8) & 0xFF)
        output[off + 2] = UInt8((newVal >> 16) & 0xFF)
        output[off + 3] = UInt8((newVal >> 24) & 0xFF)
        state += 1
    }

    @inline(__always)
    private func appendUInt16LE(_ v: UInt16) {
        output.append(UInt8(v & 0xFF))
        output.append(UInt8((v >> 8) & 0xFF))
    }

    /// PUSH_OP from dxvenc.c. Encodes one back-reference distance `idx` as a
    /// 2-bit op, optionally trailed by 1 or 2 bytes of payload.
    @inline(__always)
    private func pushOp(idx: UInt32, x: UInt32) {
        if state == 16 {
            // Allocate a new op-packing dword, zero-initialized.
            let off = output.count
            output.append(0)
            output.append(0)
            output.append(0)
            output.append(0)
            dwordOffset = off
            state = 0
        }
        let op: UInt32
        if idx >= 0x102 * x {
            op = 3
            let v: UInt32 = (idx / x) &- 0x102
            output.append(UInt8(v & 0xFF))
            output.append(UInt8((v >> 8) & 0xFF))
        } else if idx >= 2 * x {
            op = 2
            let v: UInt32 = (idx / x) &- 2
            output.append(UInt8(v & 0xFF))
        } else if idx == x {
            op = 1
        } else {
            op = 0
        }
        // OR `op << (state*2)` into the dword at dwordOffset (LE32).
        let off = dwordOffset
        let cur = UInt32(output[off]) |
                 (UInt32(output[off + 1]) << 8) |
                 (UInt32(output[off + 2]) << 16) |
                 (UInt32(output[off + 3]) << 24)
        let newVal = cur | (op << (state * 2))
        output[off]     = UInt8(newVal & 0xFF)
        output[off + 1] = UInt8((newVal >> 8) & 0xFF)
        output[off + 2] = UInt8((newVal >> 16) & 0xFF)
        output[off + 3] = UInt8((newVal >> 24) & 0xFF)
        state += 1
    }

    @inline(__always)
    private func appendUInt32LE(_ v: UInt32) {
        output.append(UInt8(v & 0xFF))
        output.append(UInt8((v >> 8) & 0xFF))
        output.append(UInt8((v >> 16) & 0xFF))
        output.append(UInt8((v >> 24) & 0xFF))
    }
}

// MARK: - Endian-explicit reads (file-private)

@inline(__always)
fileprivate func readUInt32LE(_ p: UnsafePointer<UInt8>, byteOffset: Int) -> UInt32 {
    let q = p.advanced(by: byteOffset)
    return UInt32(q[0]) |
          (UInt32(q[1]) << 8) |
          (UInt32(q[2]) << 16) |
          (UInt32(q[3]) << 24)
}

@inline(__always)
fileprivate func readUInt64LE(_ p: UnsafePointer<UInt8>, byteOffset: Int) -> UInt64 {
    let q = p.advanced(by: byteOffset)
    return UInt64(q[0]) |
          (UInt64(q[1]) <<  8) |
          (UInt64(q[2]) << 16) |
          (UInt64(q[3]) << 24) |
          (UInt64(q[4]) << 32) |
          (UInt64(q[5]) << 40) |
          (UInt64(q[6]) << 48) |
          (UInt64(q[7]) << 56)
}
