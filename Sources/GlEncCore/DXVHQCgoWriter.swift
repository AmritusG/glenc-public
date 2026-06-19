// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Encoder-side derivation of FFmpeg libavcodec/dxv.c decoder routines.
// Original C: Copyright (C) 2015 Vittorio Giovara; (C) 2018 Paul B Mahol.
// Licensed under LGPL-2.1-or-later; this Swift derivation preserves that
// license. See THIRD-PARTY-NOTICES.md.
/*
 * DXVHQCgoWriter — encoder side of FFmpeg's `dxv_decompress_cgo` and
 * its yo / cocg orchestrators (libavcodec/dxv.c lines 301..637).
 *
 * Encodes a sequence of BC4 blocks (yo path: one stream; cocg path:
 * two interleaved channels) into:
 *   - texData:   the "BC4 data" byte stream the decoder consumes
 *     between `data_start` and the opcode-stream encoding. Mix of
 *     literal block bytes and back-reference / RLE driver bytes.
 *   - opcodes0:  the opcode byte stream for the (first / only) channel.
 *   - opcodes1:  the opcode byte stream for the second channel (cocg
 *     only). Empty for yo.
 *
 * Phase 4A baseline uses three opcodes:
 *   - op 0 (RLE init):    1 op byte + 1 literal byte; covers v+4
 *     consecutive blocks that match `prev`. The first call writes one
 *     RLE block immediately (the `goto done` path) and seeds `state =
 *     v+3` for the following v+3 calls. Caps each op-0 at v=254 (=258
 *     blocks); for longer runs emits multiple op-0's.
 *   - op 1 (copy prev):   1 op byte, 0 literals; covers exactly 1
 *     block. Used for runs of length 1..3 where op-0's 4-block minimum
 *     doesn't apply.
 *   - op 3 (8 literal):   1 op byte + 8 literal bytes; covers 1 block
 *     of arbitrary content. The fallback for any block that doesn't
 *     match `prev`.
 *
 * Pass C confirmed `~88%` of testsrc2 blocks are "implicit" (RLE /
 * state-machine driven). Ops 0+1 cover those; op 3 covers the
 * remaining ~12%. Lookup-table ops (4..11, 14..16) and back-ref ops
 * (2, 7, 12, 17) are encoder discretion and deferred to v0.4.1 size
 * optimization.
 *
 * The encoder mirrors the decoder's hash-table updates SEMANTICALLY
 * (it does not need to actually populate tab0/tab1 for ops 1/3, since
 * those ops never read them — op 3's tab-write is decoder-internal).
 *
 * For the cocg path: the state machine per channel is independent.
 * Each call to channel-0's cgo emits 8 bytes from one Co block; then
 * channel-1's cgo emits 8 bytes from the paired Cg block. The
 * decoder loops `while (dst + 10 < tex_data + tex_size)` doing
 * ch0/ch1 alternately. Our encoder walks `i` from 1 to
 * `blockCountPerChannel - 1`, emitting one block per channel per
 * iteration, with state-driven RLE skips.
 */

import Foundation

public struct CgoEncoderOutput {
    public let texData: [UInt8]
    public let opcodes0: [UInt8]
    /// For yo this is empty; for cocg this is the channel-1 stream.
    public let opcodes1: [UInt8]
}

public enum DXVHQCgoWriter {

    // MARK: - Yo path (luma plane)

    /// Encode a luma BC4 plane via the yo state machine.
    /// `blocks` is `blockCount * 8` bytes (one BC4 block per 8 bytes,
    /// row-major over plane block coords).
    public static func encodeYo(blocks: [UInt8], blockCount: Int) -> CgoEncoderOutput {
        precondition(blocks.count == blockCount * 8)
        precondition(blockCount >= 1, "yo path requires at least one block")

        var texData = [UInt8]()
        texData.reserveCapacity(blockCount * 8)
        var opcodes = [UInt8]()
        opcodes.reserveCapacity(blockCount)

        // First block is literal — written verbatim and seeds the
        // (unused-by-our-opcodes) hash tables on the decoder side.
        texData.append(contentsOf: blocks[0..<8])

        var state = ChannelState()
        state.prev = Array(blocks[0..<8])

        var i = 1
        while i < blockCount {
            let blockStart = i * 8
            let cur = Array(blocks[blockStart..<(blockStart + 8)])
            i = emitBlockYo(
                cur: cur, allBlocks: blocks, blockIndex: i, blockCount: blockCount,
                state: &state, texData: &texData, opcodes: &opcodes
            )
        }

        return CgoEncoderOutput(texData: texData, opcodes0: opcodes, opcodes1: [])
    }

    /// Per-iteration emit for yo. Returns the next `i` (jumps past an
    /// op-0 run).
    @inline(__always)
    private static func emitBlockYo(
        cur: [UInt8],
        allBlocks: [UInt8],
        blockIndex i: Int,
        blockCount: Int,
        state: inout ChannelState,
        texData: inout [UInt8],
        opcodes: inout [UInt8]
    ) -> Int {
        if cur == state.prev {
            // Run-length detection.
            var R = 1
            while i + R < blockCount {
                let off = (i + R) * 8
                if equalSlice(allBlocks, range: off..<(off + 8), to: state.prev) {
                    R += 1
                } else { break }
            }
            return emitMatchRun(R: R, state: &state, texData: &texData,
                                opcodes: &opcodes, i: i)
        } else {
            // Mismatch → op 3 (8 literal bytes).
            opcodes.append(3)
            texData.append(contentsOf: cur)
            state.prev = cur
            return i + 1
        }
    }

    // MARK: - Cocg path (paired chroma planes)

    /// Encode interleaved chroma BC4 streams via the cocg state machine.
    /// `ch0Blocks` and `ch1Blocks` each carry `blockCountPerChannel * 8`
    /// bytes. The decoder reads BC4 chroma in interleaved 8-byte chunks
    /// (Co block, Cg block, Co block, Cg block, ...) so our texData
    /// stream weaves the two channels at the iteration granularity.
    public static func encodeCocg(
        ch0Blocks: [UInt8], ch1Blocks: [UInt8], blockCountPerChannel: Int
    ) -> CgoEncoderOutput {
        precondition(ch0Blocks.count == blockCountPerChannel * 8)
        precondition(ch1Blocks.count == blockCountPerChannel * 8)
        precondition(blockCountPerChannel >= 1)

        var texData = [UInt8]()
        texData.reserveCapacity(blockCountPerChannel * 16)
        var ops0 = [UInt8]()
        var ops1 = [UInt8]()
        ops0.reserveCapacity(blockCountPerChannel)
        ops1.reserveCapacity(blockCountPerChannel)

        // First "block" of cocg = 16 bytes literal (Co[0] + Cg[0]).
        texData.append(contentsOf: ch0Blocks[0..<8])
        texData.append(contentsOf: ch1Blocks[0..<8])

        var s0 = ChannelState()
        s0.prev = Array(ch0Blocks[0..<8])
        var s1 = ChannelState()
        s1.prev = Array(ch1Blocks[0..<8])

        // Mirror the decoder's loop bound: while (dst + 10 < tex_data + tex_size).
        // Per iter we write 16 bytes (8 from each channel). The bound is
        // equivalent to "all paired blocks beyond block 0". For chroma
        // plane sizes that are multiples of 16 (always true for HQ at
        // 16-aligned coded dims) `blockCountPerChannel - 1` is exactly
        // the number of pairs left to emit.
        var i = 1
        while i < blockCountPerChannel {
            // Channel 0 step.
            if s0.rleRemaining > 0 {
                s0.rleRemaining -= 1
            } else {
                let off = i * 8
                let cur0 = Array(ch0Blocks[off..<(off + 8)])
                if cur0 == s0.prev {
                    var R = 1
                    while i + R < blockCountPerChannel {
                        let aoff = (i + R) * 8
                        if equalSlice(ch0Blocks, range: aoff..<(aoff + 8), to: s0.prev) {
                            R += 1
                        } else { break }
                    }
                    // For cocg, run-length cannot exceed the iterations
                    // we'll see this channel — i.e. `blockCountPerChannel - i`.
                    let useR = min(R, 258)
                    if useR >= 4 {
                        ops0.append(0)
                        texData.append(UInt8(useR - 4))
                        s0.rleRemaining = useR - 1
                    } else {
                        ops0.append(1)
                    }
                } else {
                    ops0.append(3)
                    texData.append(contentsOf: cur0)
                    s0.prev = cur0
                }
            }

            // Channel 1 step.
            if s1.rleRemaining > 0 {
                s1.rleRemaining -= 1
            } else {
                let off = i * 8
                let cur1 = Array(ch1Blocks[off..<(off + 8)])
                if cur1 == s1.prev {
                    var R = 1
                    while i + R < blockCountPerChannel {
                        let aoff = (i + R) * 8
                        if equalSlice(ch1Blocks, range: aoff..<(aoff + 8), to: s1.prev) {
                            R += 1
                        } else { break }
                    }
                    let useR = min(R, 258)
                    if useR >= 4 {
                        ops1.append(0)
                        texData.append(UInt8(useR - 4))
                        s1.rleRemaining = useR - 1
                    } else {
                        ops1.append(1)
                    }
                } else {
                    ops1.append(3)
                    texData.append(contentsOf: cur1)
                    s1.prev = cur1
                }
            }

            i += 1
        }

        return CgoEncoderOutput(texData: texData, opcodes0: ops0, opcodes1: ops1)
    }

    // MARK: - Shared

    private struct ChannelState {
        var prev: [UInt8] = []
        /// How many further iterations this channel skips opcode emit
        /// because an earlier op-0 set state=v+3 (then it drains).
        var rleRemaining: Int = 0
    }

    /// Encode a yo-style run of length R starting at iteration i.
    /// Returns the next iteration index (i + R if op-0 was used, else i + 1).
    @inline(__always)
    private static func emitMatchRun(
        R: Int,
        state: inout ChannelState,
        texData: inout [UInt8],
        opcodes: inout [UInt8],
        i: Int
    ) -> Int {
        // For yo we don't carry rleRemaining across iterations — we
        // consume the whole run within this single call and advance `i`
        // by R. (rleRemaining is only useful for cocg where iterations
        // alternate channels.)
        if R >= 4 {
            let useR = min(R, 258)
            opcodes.append(0)
            texData.append(UInt8(useR - 4))
            return i + useR
        } else {
            // R in [1, 3]: emit single op 1 (one match block), let the
            // caller's loop pick up the next iteration to detect more
            // matches.
            opcodes.append(1)
            return i + 1
        }
    }

    /// Byte-equal check between a slice of `buf[range]` and `target`
    /// without allocating an Array copy of the slice. Avoids the
    /// `Array(buf[range]) == target` allocation that shows up in
    /// profiles when called per BC4 block.
    @inline(__always)
    private static func equalSlice(_ buf: [UInt8], range: Range<Int>, to target: [UInt8]) -> Bool {
        guard range.count == target.count else { return false }
        let base = range.lowerBound
        for j in 0..<target.count where buf[base + j] != target[j] {
            return false
        }
        return true
    }
}
