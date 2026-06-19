// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Faithful Swift port of the DXV decoder in FFmpeg's libavcodec/dxv.c.
// Upstream © Vittorio Giovara <vittorio.giovara@gmail.com> and
//          © Paul B Mahol <onemda@gmail.com> (the FFmpeg project).
// FFmpeg is licensed LGPL-2.1-or-later; this port inherits that license.
// See THIRD-PARTY-NOTICES.md and LICENSES/LGPL-2.1.txt.
//
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation

/// HQ DXV cgo (Compressed Group of Operations) state machine and the
/// `dxv_decompress_yo` orchestrator that drives it for the luma path.
///
/// Faithful port of FFmpeg's `dxv_decompress_cgo` and
/// `dxv_decompress_yo` from libavcodec/dxv.c.
///
/// The cgo state machine reconstructs DXT-like 8-byte blocks one at a
/// time. Each call to `decompressCgo` emits exactly 8 bytes to `dst`
/// (advancing it by 8). Block content is determined by:
///   - The current `state` (state>0 means "RLE: copy previous block")
///   - The next opcode in the opcode stream (one of 0..17)
///   - Literal data bytes from the input (`gb`)
///   - Back-references via the `tab0`/`tab1` hash tables
///
/// Hash tables index pointers into the already-emitted tex_data,
/// keyed by hashes of partial block content (Knuth's golden ratio
/// multiplier). They're populated as decompression progresses;
/// later opcodes reference them for repeated patterns.
enum DXVHQCgoDecoder {

    enum DecodeError: Error, CustomStringConvertible {
        case truncatedInput(needed: Int, available: Int, where: String)
        case opcodeIndexOutOfRange(idx: Int, opSize: Int)
        case nullTabReference(table: String, key: Int)
        case backRefOutOfBounds(v: Int, dstOffset: Int)
        case texSizeOverflow(dstOffset: Int, texSize: Int)
        case invalidOpOffset(Int)

        var description: String {
            switch self {
            case .truncatedInput(let n, let a, let w):
                return "DXV HQ cgo: truncated at \(w) (need \(n), have \(a))"
            case .opcodeIndexOutOfRange(let i, let s):
                return "DXV HQ cgo: opcode index \(i) >= opSize \(s)"
            case .nullTabReference(let t, let k):
                return "DXV HQ cgo: null \(t)[\(k)] reference (back-ref into uninitialized hash slot)"
            case .backRefOutOfBounds(let v, let d):
                return "DXV HQ cgo: back-ref \(v) exceeds dstOffset \(d)"
            case .texSizeOverflow(let d, let t):
                return "DXV HQ cgo: dstOffset+8 (\(d + 8)) > texSize (\(t))"
            case .invalidOpOffset(let v):
                return "DXV HQ cgo: invalid op_offset \(v)"
            }
        }
    }

    /// Mutable state carried across cgo calls within one yo/cocg pass.
    /// Mirrors FFmpeg's by-reference parameters (oindex, statep, dstp).
    struct CgoState {
        /// Current write position into texData (byte offset).
        var dstOffset: Int = 0
        /// Current read position into opcodes ([UInt8] array).
        var oi: Int = 0
        /// RLE state: when >0, current block is a copy of (dst-8-offset);
        /// decrement and continue. When 0, fetch new opcode.
        var state: Int = 0
        /// Current read position in the literal data stream (gb cursor).
        var gbCursor: Int = 0
    }

    /// Run the yo state machine: decode `texSize` bytes of BC4 luma
    /// blocks into `texData` from `payload[dataStart..]` using
    /// `opData` as the opcode stream.
    ///
    /// Caller is responsible for having read the yo header
    /// (op_offset, op_size) and extracted the opcode buffer; this
    /// function just runs the state machine.
    ///
    /// Returns the final input cursor (where the literal data stream
    /// stopped). The opcode stream's consumed bytes is tracked
    /// separately by the opcode decompressor.
    static func runYoStateMachine(
        payload: [UInt8],
        dataStart: Int,
        texData: UnsafeMutablePointer<UInt8>,
        texSize: Int,
        opData: [UInt8],
        opSize: Int
    ) throws -> (gbCursor: Int, opcodesConsumed: Int) {
        // First block: literal 8 bytes from gb, also seeds tab0/tab1.
        var cursor = dataStart
        guard cursor + 8 <= payload.count else {
            throw DecodeError.truncatedInput(
                needed: 8, available: payload.count - cursor, where: "yo first block")
        }
        let v = readLE32(payload, cursor); cursor += 4
        let vv = readLE32(payload, cursor); cursor += 4

        var tab0 = [Int](repeating: -1, count: 256)
        var tab1 = [Int](repeating: -1, count: 256)

        writeLE32(texData, 0, v)
        writeLE32(texData, 4, vv)
        let firstHashTab0 = goldenHash16(UInt16(truncatingIfNeeded: v))
        tab0[firstHashTab0] = 0
        let dstPlus2_first = (v >> 16) | (vv << 16)
        let firstHashTab1 = goldenHash24(dstPlus2_first & 0xFFFFFF)
        tab1[firstHashTab1] = 2

        var st = CgoState()
        st.dstOffset = 8
        st.oi = 0
        st.state = 0
        st.gbCursor = cursor

        while st.dstOffset < texSize {
            do {
                try decompressCgo(
                    payload: payload,
                    texData: texData, texSize: texSize,
                    opData: opData, opSize: opSize,
                    tab0: &tab0, tab1: &tab1,
                    offset: 0, state: &st)
            } catch {
                // On error, dump rich diagnostic context. This is
                // critical for any future bringup: the cgo state
                // machine has many failure modes and the surrounding
                // state at the failure point is what tells us which
                // one fired.
                let preDst = st.dstOffset
                let writtenSnapshot = (0..<min(preDst + 8, 64)).map {
                    String(format: "%02x", texData[$0])
                }.joined(separator: " ")
                print("Glance/hq:   ❌ block @ dstOffset=\(preDst) oi=\(st.oi) state=\(st.state) gb=\(st.gbCursor)")
                print("Glance/hq:   tex[0..\(min(preDst + 8, 64))]: \(writtenSnapshot)")
                throw error
            }
        }

        return (gbCursor: st.gbCursor, opcodesConsumed: st.oi)
    }

    /// Run the cocg state machine: decode `texSize` bytes of BC5
    /// chroma blocks (16 bytes each = two BC4 blocks) into `texData`
    /// from `payload[dataStart..]` using `opData0` (channel 0
    /// opcodes, e.g. Co) and `opData1` (channel 1 opcodes, e.g. Cg).
    ///
    /// Caller is responsible for having read the cocg header
    /// (op_offset, op_size0, op_size1) and extracted both opcode
    /// buffers; this function just runs the state machine.
    ///
    /// Returns the final input cursor and per-channel opcode
    /// consumption counts (sanity check vs op_size).
    static func runCocgStateMachine(
        payload: [UInt8],
        dataStart: Int,
        texData: UnsafeMutablePointer<UInt8>,
        texSize: Int,
        opData0: [UInt8], opSize0: Int,
        opData1: [UInt8], opSize1: Int
    ) throws -> (gbCursor: Int, opcodes0Consumed: Int, opcodes1Consumed: Int) {
        // First "block" is 16 bytes literal — full BC5 block (two
        // halves: bytes [0..7] = channel 0, bytes [8..15] = channel 1).
        // Each half-block seeds its own pair of hash tables.
        var cursor = dataStart
        guard cursor + 16 <= payload.count else {
            throw DecodeError.truncatedInput(
                needed: 16, available: payload.count - cursor, where: "cocg first block")
        }
        let v0 = readLE32(payload, cursor); cursor += 4
        let v1 = readLE32(payload, cursor); cursor += 4
        let v2 = readLE32(payload, cursor); cursor += 4
        let v3 = readLE32(payload, cursor); cursor += 4

        // Four hash tables: tab0/tab1 for channel 0, tab2/tab3 for
        // channel 1. Independent — never shared across channels.
        var tab0 = [Int](repeating: -1, count: 256)
        var tab1 = [Int](repeating: -1, count: 256)
        var tab2 = [Int](repeating: -1, count: 256)
        var tab3 = [Int](repeating: -1, count: 256)

        // Write 16 literal bytes.
        writeLE32(texData, 0, v0)
        writeLE32(texData, 4, v1)
        writeLE32(texData, 8, v2)
        writeLE32(texData, 12, v3)

        // Seed channel-0 hash tables from bytes [0..1] and [2..4].
        // tab0[hash16(LE16(dst[0..1]))] = 0
        let hash0_0 = goldenHash16(UInt16(truncatingIfNeeded: v0))
        tab0[hash0_0] = 0
        // dst[2..5] = (v0 >> 16) | (v1 << 16). Take low 24 bits.
        let dst2 = (v0 >> 16) | (v1 << 16)
        let hash0_1 = goldenHash24(dst2 & 0xFFFFFF)
        tab1[hash0_1] = 2

        // Seed channel-1 hash tables from bytes [8..9] and [10..12].
        // tab2[hash16(LE16(dst[8..9]))] = 8
        let hash1_0 = goldenHash16(UInt16(truncatingIfNeeded: v2))
        tab2[hash1_0] = 8
        // dst[10..13] = (v2 >> 16) | (v3 << 16). Take low 24 bits.
        let dst10 = (v2 >> 16) | (v3 << 16)
        let hash1_1 = goldenHash24(dst10 & 0xFFFFFF)
        tab3[hash1_1] = 10

        // Two state machines, one per channel, alternating.
        var st0 = CgoState()
        st0.dstOffset = 16              // dst starts after the 16-byte literal
        st0.oi = 0
        st0.state = 0
        st0.gbCursor = cursor

        var st1 = CgoState()
        // st1's dstOffset will be set fresh each iteration to follow
        // st0's writes. The "current" dstOffset for cgo is whatever
        // we pass in via the state struct.
        st1.oi = 0
        st1.state = 0
        st1.gbCursor = cursor           // shared gb cursor — must keep st0/st1.gbCursor in sync

        // Loop condition matches FFmpeg: while (dst + 10 < tex_data + tex_size).
        // Each iteration writes 16 bytes (two cgo calls × 8 bytes).
        // tex_size is a multiple of 16 for HQ chroma, so this terminates cleanly.
        while st0.dstOffset + 10 < texSize {
            // Channel 0 cgo (offset=8: back-refs reach back 16 bytes,
            // i.e. one full chroma block).
            do {
                try decompressCgo(
                    payload: payload,
                    texData: texData, texSize: texSize,
                    opData: opData0, opSize: opSize0,
                    tab0: &tab0, tab1: &tab1,
                    offset: 8, state: &st0)
            } catch {
                let preDst = st0.dstOffset
                let snap = (0..<min(preDst + 8, 80)).map {
                    String(format: "%02x", texData[$0])
                }.joined(separator: " ")
                print("Glance/hq:   ❌ cocg ch0 block @ dstOffset=\(preDst) oi=\(st0.oi) state=\(st0.state) gb=\(st0.gbCursor)")
                print("Glance/hq:   tex[0..\(min(preDst + 8, 80))]: \(snap)")
                throw error
            }

            // Channel 1 cgo. After st0 writes 8 bytes, dst is at
            // st0.dstOffset (which got incremented). st1 picks up
            // from there. We need st1's state struct to reflect
            // current dst, current gb cursor, but its OWN oi/state.
            st1.dstOffset = st0.dstOffset
            st1.gbCursor = st0.gbCursor
            do {
                try decompressCgo(
                    payload: payload,
                    texData: texData, texSize: texSize,
                    opData: opData1, opSize: opSize1,
                    tab0: &tab2, tab1: &tab3,
                    offset: 8, state: &st1)
            } catch {
                let preDst = st1.dstOffset
                let snap = (0..<min(preDst + 8, 80)).map {
                    String(format: "%02x", texData[$0])
                }.joined(separator: " ")
                print("Glance/hq:   ❌ cocg ch1 block @ dstOffset=\(preDst) oi=\(st1.oi) state=\(st1.state) gb=\(st1.gbCursor)")
                print("Glance/hq:   tex[0..\(min(preDst + 8, 80))]: \(snap)")
                throw error
            }

            // Sync st0 forward to where st1 left off.
            st0.dstOffset = st1.dstOffset
            st0.gbCursor = st1.gbCursor
        }

        return (gbCursor: st0.gbCursor,
                opcodes0Consumed: st0.oi,
                opcodes1Consumed: st1.oi)
    }

    // MARK: - cgo state machine (one block per call)

    /// Emit exactly 8 bytes at texData[state.dstOffset], advancing
    /// state.dstOffset by 8. May consume one or more bytes from
    /// payload[state.gbCursor], one byte from opData[state.oi], and
    /// may update tab0/tab1 hash tables.
    static func decompressCgo(
        payload: [UInt8],
        texData: UnsafeMutablePointer<UInt8>, texSize: Int,
        opData: [UInt8], opSize: Int,
        tab0: inout [Int], tab1: inout [Int],
        offset: Int,
        state: inout CgoState
    ) throws {
        let dstOff = state.dstOffset

        var didOpcode0 = false
        if state.state <= 0 {
            // Fetch a new opcode.
            if state.oi >= opSize {
                throw DecodeError.opcodeIndexOutOfRange(idx: state.oi, opSize: opSize)
            }
            let opcode = Int(opData[state.oi])
            state.oi += 1

            if opcode == 0 {
                // RLE-mode initiator. FFmpeg semantics: write the block,
                // set state = v+4, then `goto done` which executes the
                // SAME write again and decrements state to v+3. Net:
                // current block emitted as RLE copy, state set to v+3
                // for the next v+3 blocks (also RLE copies via the else
                // branch).
                guard state.gbCursor < payload.count else {
                    throw DecodeError.truncatedInput(
                        needed: 1, available: 0, where: "cgo opcode 0 v")
                }
                var v = Int(payload[state.gbCursor]); state.gbCursor += 1
                if v == 255 {
                    repeat {
                        guard state.gbCursor + 2 <= payload.count else {
                            throw DecodeError.truncatedInput(
                                needed: 2, available: payload.count - state.gbCursor,
                                where: "cgo opcode 0 ext")
                        }
                        let opcode2 = Int(readLE16(payload, state.gbCursor))
                        state.gbCursor += 2
                        v += opcode2
                        if opcode2 != 0xFFFF { break }
                    } while true
                }
                state.state = v + 4
                didOpcode0 = true
                // Fall through to the "done" block (write + decrement).
            } else {
                // opcode is 1..17, dispatch to the big switch.
                try cgoOpcodeSwitch(
                    opcode: opcode,
                    payload: payload,
                    texData: texData,
                    opData: opData,
                    tab0: &tab0, tab1: &tab1,
                    offset: offset,
                    state: &state)
            }
        }

        // FFmpeg's `done:` label is reached either from `goto done`
        // (after opcode 0 sets state=v+4) or from the else branch
        // (state>0 RLE continuation). In both cases, write RLE copy +
        // decrement state.
        if didOpcode0 || state.state > 0 {
            writeLE32(texData, dstOff,
                      readLE32Mem(texData, dstOff - (8 + offset)))
            writeLE32(texData, dstOff + 4,
                      readLE32Mem(texData, dstOff - (4 + offset)))
            state.state -= 1
        }

        if dstOff + 8 > texSize {
            throw DecodeError.texSizeOverflow(dstOffset: dstOff, texSize: texSize)
        }
        state.dstOffset = dstOff + 8
    }

    // MARK: - cgo opcode switch (cases 1..17)

    private static func cgoOpcodeSwitch(
        opcode: Int,
        payload: [UInt8],
        texData: UnsafeMutablePointer<UInt8>,
        opData: [UInt8],
        tab0: inout [Int], tab1: inout [Int],
        offset: Int,
        state: inout CgoState
    ) throws {
        let dstOff = state.dstOffset
        let off8 = 8 + offset

        switch opcode {
        case 1:
            // Copy previous block (8 bytes earlier).
            writeLE32(texData, dstOff, readLE32Mem(texData, dstOff - off8))
            writeLE32(texData, dstOff + 4, readLE32Mem(texData, dstOff - (4 + offset)))

        case 2:
            // Long back-reference: vv = (8+offset) * (LE16+1).
            let raw = try readGB16(payload, &state.gbCursor)
            let vv = off8 * (Int(raw) + 1)
            if vv < 0 || vv > dstOff {
                throw DecodeError.backRefOutOfBounds(v: vv, dstOffset: dstOff)
            }
            let tptr0 = dstOff - vv
            let v = readLE32Mem(texData, tptr0)
            writeLE32(texData, dstOff, v)
            writeLE32(texData, dstOff + 4, readLE32Mem(texData, tptr0 + 4))
            tab0[goldenHash16(UInt16(truncatingIfNeeded: v))] = dstOff
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 3:
            // Pure literal: 8 bytes from gb. Update both hash tables.
            let lo = try readGB32(payload, &state.gbCursor)
            let hi = try readGB32(payload, &state.gbCursor)
            writeLE32(texData, dstOff, lo)
            writeLE32(texData, dstOff + 4, hi)
            tab0[goldenHash16(readLE16Mem(texData, dstOff))] = dstOff
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 4:
            // Mixed: tab1 lookup for high bytes (bytes 2..4), literal
            // for bytes 0..1 and 5..7.
            let key = Int(try readGB8(payload, &state.gbCursor))
            let tptr3 = tab1[key]
            if tptr3 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: key) }
            let lit01 = try readGB16(payload, &state.gbCursor)
            writeLE16(texData, dstOff, lit01)
            writeLE16(texData, dstOff + 2, readLE16Mem(texData, tptr3))
            texData[dstOff + 4] = texData[tptr3 + 2]
            let lit57 = try readGB16(payload, &state.gbCursor)
            writeLE16(texData, dstOff + 5, lit57)
            texData[dstOff + 7] = try readGB8(payload, &state.gbCursor)
            tab0[goldenHash16(readLE16Mem(texData, dstOff))] = dstOff

        case 5:
            // Variant: tab1 lookup for low half of bytes 5..7.
            let key = Int(try readGB8(payload, &state.gbCursor))
            let tptr3 = tab1[key]
            if tptr3 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: key) }
            writeLE16(texData, dstOff, try readGB16(payload, &state.gbCursor))
            writeLE16(texData, dstOff + 2, try readGB16(payload, &state.gbCursor))
            texData[dstOff + 4] = try readGB8(payload, &state.gbCursor)
            writeLE16(texData, dstOff + 5, readLE16Mem(texData, tptr3))
            texData[dstOff + 7] = texData[tptr3 + 2]
            tab0[goldenHash16(readLE16Mem(texData, dstOff))] = dstOff
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 6:
            // Two tab1 lookups (bytes 2..4 and 5..7).
            let key0 = Int(try readGB8(payload, &state.gbCursor))
            let tptr0 = tab1[key0]
            if tptr0 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: key0) }
            let key1 = Int(try readGB8(payload, &state.gbCursor))
            let tptr1 = tab1[key1]
            if tptr1 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: key1) }
            writeLE16(texData, dstOff, try readGB16(payload, &state.gbCursor))
            writeLE16(texData, dstOff + 2, readLE16Mem(texData, tptr0))
            texData[dstOff + 4] = texData[tptr0 + 2]
            writeLE16(texData, dstOff + 5, readLE16Mem(texData, tptr1))
            texData[dstOff + 7] = texData[tptr1 + 2]
            tab0[goldenHash16(readLE16Mem(texData, dstOff))] = dstOff

        case 7:
            // Long back-reference for high bytes; bytes 0..1 literal.
            let raw = try readGB16(payload, &state.gbCursor)
            let v = off8 * (Int(raw) + 1)
            if v < 0 || v > dstOff {
                throw DecodeError.backRefOutOfBounds(v: v, dstOffset: dstOff)
            }
            let tptr0 = dstOff - v
            writeLE16(texData, dstOff, try readGB16(payload, &state.gbCursor))
            writeLE16(texData, dstOff + 2, readLE16Mem(texData, tptr0 + 2))
            writeLE32(texData, dstOff + 4, readLE32Mem(texData, tptr0 + 4))
            tab0[goldenHash16(readLE16Mem(texData, dstOff))] = dstOff
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 8:
            // tab0 lookup for bytes 0..1; bytes 2..7 literal.
            let key = Int(try readGB8(payload, &state.gbCursor))
            let tptr1 = tab0[key]
            if tptr1 < 0 { throw DecodeError.nullTabReference(table: "tab0", key: key) }
            writeLE16(texData, dstOff, readLE16Mem(texData, tptr1))
            writeLE16(texData, dstOff + 2, try readGB16(payload, &state.gbCursor))
            writeLE32(texData, dstOff + 4, try readGB32(payload, &state.gbCursor))
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 9:
            // tab0 + tab1 lookups (bytes 0..1, 2..4); bytes 5..7 literal.
            let k0 = Int(try readGB8(payload, &state.gbCursor))
            let tptr1 = tab0[k0]
            if tptr1 < 0 { throw DecodeError.nullTabReference(table: "tab0", key: k0) }
            let k1 = Int(try readGB8(payload, &state.gbCursor))
            let tptr3 = tab1[k1]
            if tptr3 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: k1) }
            writeLE16(texData, dstOff, readLE16Mem(texData, tptr1))
            writeLE16(texData, dstOff + 2, readLE16Mem(texData, tptr3))
            texData[dstOff + 4] = texData[tptr3 + 2]
            writeLE16(texData, dstOff + 5, try readGB16(payload, &state.gbCursor))
            texData[dstOff + 7] = try readGB8(payload, &state.gbCursor)
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 10:
            // tab0 lookup for bytes 0..1; literal 2..4; tab1 for 5..7.
            let k0 = Int(try readGB8(payload, &state.gbCursor))
            let tptr1 = tab0[k0]
            if tptr1 < 0 { throw DecodeError.nullTabReference(table: "tab0", key: k0) }
            let k1 = Int(try readGB8(payload, &state.gbCursor))
            let tptr3 = tab1[k1]
            if tptr3 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: k1) }
            writeLE16(texData, dstOff, readLE16Mem(texData, tptr1))
            writeLE16(texData, dstOff + 2, try readGB16(payload, &state.gbCursor))
            texData[dstOff + 4] = try readGB8(payload, &state.gbCursor)
            writeLE16(texData, dstOff + 5, readLE16Mem(texData, tptr3))
            texData[dstOff + 7] = texData[tptr3 + 2]
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 11:
            // tab0 + 2x tab1 lookups; no literals.
            let k0 = Int(try readGB8(payload, &state.gbCursor))
            let tptr0 = tab0[k0]
            if tptr0 < 0 { throw DecodeError.nullTabReference(table: "tab0", key: k0) }
            let k1 = Int(try readGB8(payload, &state.gbCursor))
            let tptr3 = tab1[k1]
            if tptr3 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: k1) }
            let k2 = Int(try readGB8(payload, &state.gbCursor))
            let tptr1 = tab1[k2]
            if tptr1 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: k2) }
            writeLE16(texData, dstOff, readLE16Mem(texData, tptr0))
            writeLE16(texData, dstOff + 2, readLE16Mem(texData, tptr3))
            texData[dstOff + 4] = texData[tptr3 + 2]
            writeLE16(texData, dstOff + 5, readLE16Mem(texData, tptr1))
            texData[dstOff + 7] = texData[tptr1 + 2]

        case 12:
            // tab0 lookup for bytes 0..1; long back-ref for high bytes.
            let k0 = Int(try readGB8(payload, &state.gbCursor))
            let tptr1 = tab0[k0]
            if tptr1 < 0 { throw DecodeError.nullTabReference(table: "tab0", key: k0) }
            let raw = try readGB16(payload, &state.gbCursor)
            let v = off8 * (Int(raw) + 1)
            if v < 0 || v > dstOff {
                throw DecodeError.backRefOutOfBounds(v: v, dstOffset: dstOff)
            }
            let tptr0 = dstOff - v
            writeLE16(texData, dstOff, readLE16Mem(texData, tptr1))
            writeLE16(texData, dstOff + 2, readLE16Mem(texData, tptr0 + 2))
            writeLE32(texData, dstOff + 4, readLE32Mem(texData, tptr0 + 4))
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 13:
            // Copy bytes 0..1 from previous block; literal 2..7.
            writeLE16(texData, dstOff, readLE16Mem(texData, dstOff - off8))
            writeLE16(texData, dstOff + 2, try readGB16(payload, &state.gbCursor))
            writeLE32(texData, dstOff + 4, try readGB32(payload, &state.gbCursor))
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 14:
            // Copy bytes 0..1 from previous; tab1 for 2..4; literal 5..7.
            let k = Int(try readGB8(payload, &state.gbCursor))
            let tptr3 = tab1[k]
            if tptr3 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: k) }
            writeLE16(texData, dstOff, readLE16Mem(texData, dstOff - off8))
            writeLE16(texData, dstOff + 2, readLE16Mem(texData, tptr3))
            texData[dstOff + 4] = texData[tptr3 + 2]
            writeLE16(texData, dstOff + 5, try readGB16(payload, &state.gbCursor))
            texData[dstOff + 7] = try readGB8(payload, &state.gbCursor)
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 15:
            // Copy bytes 0..1 from previous; literal 2..4; tab1 for 5..7.
            let k = Int(try readGB8(payload, &state.gbCursor))
            let tptr3 = tab1[k]
            if tptr3 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: k) }
            writeLE16(texData, dstOff, readLE16Mem(texData, dstOff - off8))
            writeLE16(texData, dstOff + 2, try readGB16(payload, &state.gbCursor))
            texData[dstOff + 4] = try readGB8(payload, &state.gbCursor)
            writeLE16(texData, dstOff + 5, readLE16Mem(texData, tptr3))
            texData[dstOff + 7] = texData[tptr3 + 2]
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        case 16:
            // Copy bytes 0..1 from previous; 2 tab1 lookups; no literals.
            let k0 = Int(try readGB8(payload, &state.gbCursor))
            let tptr3 = tab1[k0]
            if tptr3 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: k0) }
            let k1 = Int(try readGB8(payload, &state.gbCursor))
            let tptr1 = tab1[k1]
            if tptr1 < 0 { throw DecodeError.nullTabReference(table: "tab1", key: k1) }
            writeLE16(texData, dstOff, readLE16Mem(texData, dstOff - off8))
            writeLE16(texData, dstOff + 2, readLE16Mem(texData, tptr3))
            texData[dstOff + 4] = texData[tptr3 + 2]
            writeLE16(texData, dstOff + 5, readLE16Mem(texData, tptr1))
            texData[dstOff + 7] = texData[tptr1 + 2]

        case 17:
            // Copy bytes 0..1 from previous; long back-ref for 2..7.
            let raw = try readGB16(payload, &state.gbCursor)
            let v = off8 * (Int(raw) + 1)
            if v < 0 || v > dstOff {
                throw DecodeError.backRefOutOfBounds(v: v, dstOffset: dstOff)
            }
            writeLE16(texData, dstOff, readLE16Mem(texData, dstOff - off8))
            writeLE16(texData, dstOff + 2, readLE16Mem(texData, dstOff - v + 2))
            writeLE32(texData, dstOff + 4, readLE32Mem(texData, dstOff - v + 4))
            tab1[goldenHash24(readLE32Mem(texData, dstOff + 2) & 0xFFFFFF)] = dstOff + 2

        default:
            // FFmpeg's `default: break;` — treat as no-op. Could happen
            // with corrupted opcodes but we don't error.
            break
        }
    }

    // MARK: - Knuth golden-ratio hash

    /// Hash a 16-bit value to an 8-bit table index.
    /// FFmpeg: `0x9E3779B1 * (uint16_t)v >> 24`.
    /// The multiplication is uint32 * uint32 (overflow wraps) → take
    /// high 8 bits.
    @inline(__always)
    private static func goldenHash16(_ v: UInt16) -> Int {
        let h = UInt32(0x9E3779B1) &* UInt32(v)
        return Int(h >> 24)
    }

    @inline(__always)
    private static func goldenHash16(_ v: UInt32) -> Int {
        // For 32-bit `v`, FFmpeg casts to (uint16_t) first, taking
        // low 16 bits.
        let lo16 = UInt16(truncatingIfNeeded: v)
        return goldenHash16(lo16)
    }

    /// Hash a 24-bit value (low 24 bits used) to an 8-bit table index.
    /// FFmpeg: `0x9E3779B1 * (AV_RL32(...) & 0xFFFFFF) >> 24`.
    @inline(__always)
    private static func goldenHash24(_ v: UInt32) -> Int {
        let masked = v & 0xFFFFFF
        let h = UInt32(0x9E3779B1) &* masked
        return Int(h >> 24)
    }

    // MARK: - Bytestream readers (gb-style; throw on truncation)

    @inline(__always)
    private static func readGB8(_ data: [UInt8], _ cursor: inout Int) throws -> UInt8 {
        guard cursor < data.count else {
            throw DecodeError.truncatedInput(needed: 1, available: 0, where: "gb8")
        }
        let b = data[cursor]
        cursor += 1
        return b
    }

    @inline(__always)
    private static func readGB16(_ data: [UInt8], _ cursor: inout Int) throws -> UInt16 {
        guard cursor + 2 <= data.count else {
            throw DecodeError.truncatedInput(
                needed: 2, available: data.count - cursor, where: "gb16")
        }
        let v = UInt16(data[cursor]) | (UInt16(data[cursor + 1]) << 8)
        cursor += 2
        return v
    }

    @inline(__always)
    private static func readGB32(_ data: [UInt8], _ cursor: inout Int) throws -> UInt32 {
        guard cursor + 4 <= data.count else {
            throw DecodeError.truncatedInput(
                needed: 4, available: data.count - cursor, where: "gb32")
        }
        let v = UInt32(data[cursor])
            | (UInt32(data[cursor + 1]) << 8)
            | (UInt32(data[cursor + 2]) << 16)
            | (UInt32(data[cursor + 3]) << 24)
        cursor += 4
        return v
    }

    // MARK: - Memory readers/writers (no bounds check; caller-side or
    // tex-size-checked at write loop).

    @inline(__always)
    private static func readLE16Mem(_ p: UnsafeMutablePointer<UInt8>, _ off: Int) -> UInt16 {
        return UInt16(p[off]) | (UInt16(p[off + 1]) << 8)
    }

    @inline(__always)
    private static func readLE32Mem(_ p: UnsafeMutablePointer<UInt8>, _ off: Int) -> UInt32 {
        return UInt32(p[off])
            | (UInt32(p[off + 1]) << 8)
            | (UInt32(p[off + 2]) << 16)
            | (UInt32(p[off + 3]) << 24)
    }

    @inline(__always)
    private static func writeLE16(_ p: UnsafeMutablePointer<UInt8>, _ off: Int, _ v: UInt16) {
        p[off] = UInt8(truncatingIfNeeded: v)
        p[off + 1] = UInt8(truncatingIfNeeded: v >> 8)
    }

    @inline(__always)
    private static func writeLE32(_ p: UnsafeMutablePointer<UInt8>, _ off: Int, _ v: UInt32) {
        p[off] = UInt8(truncatingIfNeeded: v)
        p[off + 1] = UInt8(truncatingIfNeeded: v >> 8)
        p[off + 2] = UInt8(truncatingIfNeeded: v >> 16)
        p[off + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    // MARK: - Array readers (zero-indexed)

    @inline(__always)
    private static func readLE16(_ data: [UInt8], _ off: Int) -> UInt16 {
        return UInt16(data[off]) | (UInt16(data[off + 1]) << 8)
    }

    @inline(__always)
    private static func readLE32(_ data: [UInt8], _ off: Int) -> UInt32 {
        return UInt32(data[off])
            | (UInt32(data[off + 1]) << 8)
            | (UInt32(data[off + 2]) << 16)
            | (UInt32(data[off + 3]) << 24)
    }
}
