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

/// Opcode decompression machinery for DXV HQ variants (YCG6, YG10).
///
/// HQ variants store an "opcode buffer" alongside the actual texture
/// data. Each byte in the opcode buffer is a 1-of-18 instruction
/// (0..17) that drives `dxv_decompress_cgo`'s big switch statement to
/// reconstruct DXT-like blocks via copies, hash-table lookups, and
/// literal data. The opcode buffer itself is compressed using one of
/// three schemes selected by a 2-bit prefix flag:
///
///   - flag & 3 == 0: opcode buffer is uncompressed; copy verbatim.
///   - flag & 3 == 1: opcode buffer is a single byte repeated;
///     `memset` to that value.
///   - otherwise: Huffman-coded with a dynamic table that's transmitted
///     in a custom packed format ("ltable" → "optable" two-stage build).
///
/// This is unrelated to and structurally different from the 2-bit
/// opcode stream used for DXT1/DXT5 (which addresses 4-byte elements
/// directly). HQ opcodes drive an inner state machine that produces
/// BC4/BC5-format luma/chroma block data for further GPU/CPU
/// decompression.
///
/// Faithful port of FFmpeg's `fill_ltable`, `fill_optable`,
/// `get_opcodes`, and `dxv_decompress_opcodes` from libavcodec/dxv.c.
enum DXVHQOpcodeDecoder {

    enum DecodeError: Error, CustomStringConvertible {
        case truncatedInput(needed: Int, available: Int)
        case invalidLTable(String)
        case invalidOpcodeStream(String)
        case shortBufferRead(expected: Int, got: Int)

        var description: String {
            switch self {
            case .truncatedInput(let n, let a):
                return "DXV HQ opcode: truncated input (needed \(n), have \(a))"
            case .invalidLTable(let msg):
                return "DXV HQ opcode: invalid ltable — \(msg)"
            case .invalidOpcodeStream(let msg):
                return "DXV HQ opcode: invalid stream — \(msg)"
            case .shortBufferRead(let e, let g):
                return "DXV HQ opcode: short buffer (expected \(e), got \(g))"
            }
        }
    }

    /// Result of decompressOpcodes: the opcode bytes plus the number of
    /// input bytes consumed. Caller advances its read pointer by
    /// `bytesConsumed`. Output is exactly `opSize` bytes.
    struct Result {
        let opcodes: Data
        let bytesConsumed: Int
    }

    /// Internal opcode-table entry mirroring FFmpeg's `OpcodeTable`
    /// struct: `next` is a signed offset into the table for the next
    /// state, `val1` is the opcode value (0..17), `val2` is a bit-shift
    /// width used during decoding.
    private struct OpEntry {
        var next: Int16 = 0
        var val1: UInt8 = 0
        var val2: UInt8 = 0
    }

    /// Decompress `opSize` bytes of opcode stream from `input` starting
    /// at `offset`. Returns the decoded opcodes plus the number of
    /// bytes consumed from input. Caller is responsible for advancing
    /// its read cursor.
    ///
    /// `input` may be a Data slice with a non-zero startIndex (e.g.
    /// the result of `subdata(in:)`). To avoid that pitfall throughout
    /// the inner machinery, we materialize into `[UInt8]` once here.
    /// We also append 4 trailing zero bytes (mirroring FFmpeg's
    /// `AV_INPUT_BUFFER_PADDING_SIZE`) so the bitstream walker can
    /// safely read 4 bytes at the last valid byte position. The cost
    /// is a single memcpy + small append per HQ frame; negligible.
    static func decompressOpcodes(input: Data, offset: Int, opSize: Int) throws -> Result {
        var bytes = Array(input)
        bytes.append(contentsOf: [0, 0, 0, 0])
        return try decompressOpcodesArray(input: bytes, offset: offset, opSize: opSize)
    }

    /// Internal entry point operating on a [UInt8] (zero-indexed).
    /// Public type uses Data for ergonomics.
    ///
    /// IMPORTANT: This function expects `input` to have at least 4
    /// bytes of trailing padding past its logical end, mirroring
    /// FFmpeg's `AV_INPUT_BUFFER_PADDING_SIZE`. The bitstream walker
    /// in `getOpcodes` reads 4 bytes at the high-water position which
    /// is logically the last bit of valid data; without padding, that
    /// 4-byte read goes 0..3 bytes past the input buffer's end. The
    /// public Data entry point pads automatically; direct callers
    /// must do so themselves.
    static func decompressOpcodesArray(input: [UInt8], offset: Int, opSize: Int) throws -> Result {
        guard offset < input.count else {
            throw DecodeError.truncatedInput(needed: 1, available: 0)
        }
        let flag = input[offset] & 0x3
        var cursor = offset

        if flag == 0 {
            // Verbatim copy.
            cursor += 1
            guard cursor + opSize <= input.count else {
                throw DecodeError.shortBufferRead(
                    expected: opSize, got: input.count - cursor)
            }
            let opcodes = Data(input[cursor..<(cursor + opSize)])
            cursor += opSize
            return Result(opcodes: opcodes, bytesConsumed: cursor - offset)
        }

        if flag == 1 {
            // Byte-fill: read one byte, repeat it `opSize` times.
            cursor += 1
            guard cursor < input.count else {
                throw DecodeError.truncatedInput(needed: 1, available: 0)
            }
            let value = input[cursor]
            cursor += 1
            let opcodes = Data(repeating: value, count: opSize)
            return Result(opcodes: opcodes, bytesConsumed: cursor - offset)
        }

        // Otherwise: Huffman-coded with a transmitted table.
        var ltable = [UInt32](repeating: 0, count: 256)
        var nbElements = 0
        cursor = try fillLTable(input: input, offset: offset,
                                table: &ltable, nbElements: &nbElements)
        let opcodes = try getOpcodes(input: input, offset: &cursor,
                                     ltable: ltable, nbElements: nbElements,
                                     opSize: opSize)
        return Result(opcodes: opcodes, bytesConsumed: cursor - offset)
    }

    // MARK: - fill_ltable

    /// Decode the length-table from a packed 30-bit-mask + variable
    /// reload stream. The encoding starts with a 32-bit word whose low
    /// 2 bits are the flag (already known to be > 1 by the caller);
    /// the upper 30 bits are the start of the mask. As elements are
    /// extracted, the mask shifts down, and when the in-flight bit
    /// budget would drop below 16, we reload from the next 16-bit LE
    /// word in the input.
    ///
    /// Each element consumes a variable number of bits from the mask
    /// (initially 10, halving when the remaining "left" budget drops
    /// below "half"). Iterates until "left" reaches 0; final post-loop
    /// trims trailing zeros to determine the real element count.
    ///
    /// Returns the byte offset in `input` after consuming the table.
    private static func fillLTable(
        input: [UInt8], offset: Int,
        table: inout [UInt32], nbElements: inout Int
    ) throws -> Int {
        var cursor = offset
        var half: UInt32 = 512
        var bits: UInt32 = 1023
        var left: Int = 1024
        var rshift: Int = 10
        var lshift: Int = 30
        var counter = 0

        // Consume the first 32-bit LE word; mask is its upper 30 bits.
        guard cursor + 4 <= input.count else {
            throw DecodeError.truncatedInput(needed: 4, available: input.count - cursor)
        }
        var mask: UInt32 = readLE32(input, cursor) >> 2
        cursor += 4

        while left > 0 {
            if counter >= 256 {
                throw DecodeError.invalidLTable("counter exceeded 256")
            }
            if rshift < 0 || rshift > 31 {
                throw DecodeError.invalidLTable("rshift out of range: \(rshift)")
            }
            let value = bits & mask
            left -= Int(bits & mask)
            mask >>= UInt32(rshift)
            lshift -= rshift
            table[counter] = value
            counter += 1
            if lshift < 16 {
                guard cursor + 2 <= input.count else {
                    throw DecodeError.invalidLTable("truncated reload")
                }
                let inputWord = readLE16(input, cursor)
                cursor += 2
                if lshift < 0 || lshift > 31 {
                    throw DecodeError.invalidLTable("lshift out of range during reload: \(lshift)")
                }
                mask &+= UInt32(inputWord) << UInt32(lshift)
                lshift += 16
            }
            if left < Int(half) {
                half >>= 1
                bits >>= 1
                rshift -= 1
            }
        }

        // Trim trailing zeros to find real element count.
        while counter > 0 && table[counter - 1] == 0 {
            counter -= 1
        }
        if counter <= 0 {
            throw DecodeError.invalidLTable("all elements zero")
        }
        nbElements = counter
        if counter < 256 {
            for k in counter..<256 { table[k] = 0 }
        }

        // FFmpeg's dxv.c rewinds the stream by 2 bytes if lshift >= 16
        // because the last 16-bit reload was unnecessary. Mirror that.
        if lshift >= 16 {
            cursor -= 2
        }
        return cursor
    }

    // MARK: - fill_optable

    /// Build the 1024-entry decode table from the length-table. The
    /// algorithm is deliberately compact and somewhat opaque — it's a
    /// canonical Huffman-style construction where:
    ///
    ///   - `table0` holds frequency counts (one per opcode 0..nbElements-1).
    ///   - We compute prefix sums into `table2`.
    ///   - Find the first non-zero prefix sum to identify the smallest
    ///     opcode actually used.
    ///   - Walk 1024 slots in a permuted order (`x = (x - 383) & 0x3FF`)
    ///     assigning each slot the appropriate opcode based on the
    ///     prefix-sum threshold.
    ///   - For each slot, store a `next` jump and a `val2` bit-width.
    private static func fillOpTable(
        ltable: [UInt32], nbElements: Int,
        optable: inout [OpEntry]
    ) throws {
        var table2 = [UInt32](repeating: 0, count: 256)
        // table2 = prefix-sum-shifted-by-one of ltable (i.e. table2[i+1] = ltable[i+1] + table2[i] for i in 0..<n-1, with table2[0] = ltable[0])
        table2[0] = ltable[0]
        if nbElements >= 2 {
            for i in 0..<(nbElements - 1) {
                table2[i + 1] = ltable[i + 1] &+ table2[i]
                // Note: FFmpeg's loop pattern updates table2 inside the
                // condition; the increment for i happens via the final
                // expression. Effect is exactly what we have here.
            }
        }

        // Find smallest k such that table2[k] != 0. If table2[0] == 0,
        // walk forward.
        var k = 0
        if table2[0] == 0 {
            repeat {
                k += 1
                if k >= 256 {
                    throw DecodeError.invalidLTable("optable: all-zero prefix sums")
                }
            } while table2[k] == 0
        }

        // Step 1: assign val1 to each of 1024 slots based on threshold
        // crossings. Iterate i from 1024 down to 1. The C code is:
        //
        //     for (i = 1024; i > 0; i--) {
        //         for (table1[x].val1 = k; k < 256 && j > table2[k]; k++);
        //         x = (x - 383) & 0x3FF;
        //         j++;
        //     }
        //
        // The inner for-loop's INIT (`table1[x].val1 = k`) runs once
        // per outer iteration BEFORE the condition is checked, then
        // the condition+increment walk runs k forward through table2.
        // The assignment captures k as it was at the start of this
        // outer iteration; subsequent iterations may see a different k
        // if the inner walk advanced it. At the tail, k can hit 256
        // (loop exit condition), and the NEXT outer iteration assigns
        // k=256 to val1 — C truncates this to 0 via implicit uint8_t
        // cast. We use `truncatingIfNeeded` to match.
        var x: Int = 0
        var j: UInt32 = 2
        var i = 1024
        while i > 0 {
            optable[x].val1 = UInt8(truncatingIfNeeded: k)
            while k < 256 && j > table2[k] {
                k += 1
            }
            x = (x &- 383) & 0x3FF
            j &+= 1
            i -= 1
        }

        // Step 2: refresh table2 with original ltable values (we
        // mutated it via prefix sums above; the second pass needs raw
        // counts).
        if nbElements > 0 {
            for n in 0..<nbElements { table2[n] = ltable[n] }
            for n in nbElements..<256 { table2[n] = 0 }
        }

        // Step 3: per-slot val2 + next computation.
        for slot in 0..<1024 {
            let val0 = Int(optable[slot].val1)
            let val1 = table2[val0]
            table2[val0] = table2[val0] &+ 1
            // x = 31 - clz(val1). Equivalent: if val1 == 0, undefined
            // (clz(0) = 32 conventionally → x = -1). FFmpeg returns
            // INVALIDDATA when x > 10. We mirror.
            let xClz: Int
            if val1 == 0 {
                xClz = -1  // 31 - 32
            } else {
                xClz = 31 - val1.leadingZeroBitCount
            }
            if xClz > 10 {
                throw DecodeError.invalidLTable("optable: x>10 for slot \(slot)")
            }
            let val2: UInt8
            if xClz < 0 {
                // FFmpeg never explicitly handles this; in practice it
                // doesn't occur for well-formed input. Treat as 0 to
                // mirror the integer arithmetic that the C code would
                // produce (10 - (-1) = 11, which would be > 10 →
                // already caught above). Defensive: this branch is
                // unreachable.
                val2 = 0
            } else {
                val2 = UInt8(10 - xClz)
            }
            optable[slot].val2 = val2
            // next = (val1 << val2) - 1024. Both are 32-bit math; the
            // result is signed 16-bit (Int16) per FFmpeg's typedef.
            let next32 = Int32(Int(val1) << Int(val2)) - 1024
            optable[slot].next = Int16(truncatingIfNeeded: next32)
        }
    }

    // MARK: - get_opcodes

    /// Decode the actual opcode stream using the optable. The bitstream
    /// is read from a position determined by a leading size-in-bits
    /// header, walking BACKWARDS through the input from `endoffset` —
    /// FFmpeg's design works the bitstream as right-justified words
    /// indexed from a high-water offset that decreases as bits are
    /// consumed.
    private static func getOpcodes(
        input: [UInt8], offset: inout Int,
        ltable: [UInt32], nbElements: Int,
        opSize: Int
    ) throws -> Data {
        var optable = [OpEntry](repeating: OpEntry(), count: 1024)
        try fillOpTable(ltable: ltable, nbElements: nbElements, optable: &optable)

        // CRITICAL: FFmpeg captures `src = gb->buffer` BEFORE reading
        // size_in_bits. So `src + endoffset` indexes from the start of
        // the size_in_bits field, NOT from the start of the bitstream
        // data. We mirror by capturing `base` before advancing past
        // size_in_bits.
        let base = offset            // BEFORE the +=4 below

        // Read 32-bit size-in-bits header from current position.
        guard offset + 4 <= input.count else {
            throw DecodeError.truncatedInput(needed: 4, available: input.count - offset)
        }
        let sizeInBits = Int(readLE32(input, offset))
        offset += 4

        let endoffset = ((sizeInBits + 7) >> 3) - 4
        // FFmpeg requires bytesLeft >= endoffset. The walker reads 4
        // bytes at base+endoffset, going up to (base+endoffset+3).
        // FFmpeg relies on AV_INPUT_BUFFER_PADDING_SIZE (32 bytes of
        // zero padding past the logical end). We mirror that with a
        // 4-byte append in the public entry point. Logical bound is
        // unchanged; physical bound has slack.
        // Since base is BEFORE size_in_bits, we need
        // input.count - base >= endoffset + 4 to safely read.
        guard endoffset > 0,
              input.count - base >= endoffset + 4 else {
            // The +4 accounts for the padding we appended; effectively
            // requires bytesLeft (logical) >= endoffset, matching
            // FFmpeg's check.
            throw DecodeError.invalidOpcodeStream("bad endoffset \(endoffset), bytesLeft=\(input.count - base - 4)")
        }

        // FFmpeg uses src = gb->buffer (current buffer cursor BEFORE
        // reading size_in_bits), then reads from src[endoffset].
        // We use `base` for the same purpose.
        let src = input

        var pos = endoffset
        var next = readLE32(src, base + pos)
        var rshift = (((sizeInBits & 0xFF) - 1) & 7) + 15
        var lshift = 32 - rshift
        var idx = Int((next >> rshift) & 0x3FF)

        var dst = [UInt8](repeating: 0, count: opSize)
        for i in 0..<opSize {
            dst[i] = optable[idx].val1
            let val = Int(optable[idx].val2)
            let sum = val + lshift
            // x = (next << lshift) >> 1 >> (31 - val)
            // The double shift by 1 and (31 - val) preserves the sign
            // semantics in C; we use UInt32 arithmetic which already
            // gives logical shifts.
            let shifted = (next &<< UInt32(lshift)) >> 1
            let x = Int(shifted >> UInt32(31 - val))
            let newoffset = pos - (sum >> 3)
            lshift = sum & 7
            idx = x + Int(optable[idx].next)
            // Bounds-check idx — must be in [0, 1024).
            if idx < 0 || idx >= 1024 {
                throw DecodeError.invalidOpcodeStream("idx out of range: \(idx) at op \(i)")
            }
            pos = newoffset
            if pos < 0 {
                throw DecodeError.invalidOpcodeStream("pos<0 at op \(i): newoffset=\(newoffset)")
            }
            if pos > endoffset {
                throw DecodeError.invalidOpcodeStream("pos overflow at op \(i)")
            }
            // Read next 32-bit word at pos. Need 4 bytes available
            // starting at base+pos.
            guard base + pos + 4 <= input.count else {
                throw DecodeError.truncatedInput(
                    needed: 4, available: input.count - (base + pos))
            }
            next = readLE32(src, base + pos)
        }

        // Skip past the consumed bitstream: ((sizeInBits + 7) >> 3) - 4.
        let toSkip = ((sizeInBits + 7) >> 3) - 4
        offset += toSkip
        return Data(dst)
    }

    // MARK: - Little-endian readers (helpers, not throwing — caller bounds-checks)

    private static func readLE32(_ data: [UInt8], _ off: Int) -> UInt32 {
        return UInt32(data[off])
            | (UInt32(data[off + 1]) << 8)
            | (UInt32(data[off + 2]) << 16)
            | (UInt32(data[off + 3]) << 24)
    }

    private static func readLE16(_ data: [UInt8], _ off: Int) -> UInt16 {
        return UInt16(data[off]) | (UInt16(data[off + 1]) << 8)
    }
}
