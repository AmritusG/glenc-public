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

/// Decoder for the inner compression layer of DXV3 packets. After the
/// 12-byte packet header is stripped, the body is a stream of 2-bit
/// opcodes packed into 32-bit little-endian words. Each opcode addresses
/// 2-byte (DXT1) or 4-byte (DXT5) elements; the decoder produces a flat
/// stream of decompressed DXT-block bytes ready for GPU upload via
/// glCompressedTexImage2D.
///
/// This is NOT canonical LZF — that was an early misidentification. The
/// real format is DXV-specific and described by FFmpeg's dxv.c source:
///   /* This scheme addresses already decoded elements depending on
///    * 2-bit status:
///    * 0 -> copy new element
///    * 1 -> copy one element from position -x
///    * 2 -> copy one element from position -(get_byte() + 2) * x
///    * 3 -> copy one element from position -(get_16le() + 0x102) * x
///    * x is always 2 for dxt1 and 4 for dxt5. */
///
/// The decoder reads 32 bits at a time as a "checkpoint": each word
/// supplies 16 ops (2 bits each), then needs refilling. Element size
/// `x` differs per variant but the opcode logic is identical.
public enum DXVPacketDecoder {
    public enum DecodeError: Error, CustomStringConvertible {
        case packetTooSmall(size: Int)
        case unknownTag(String)
        case truncatedInput(needed: Int, available: Int)
        case backRefOutOfRange(idx: Int, pos: Int)
        case outputOverflow(produced: Int, expected: Int)

        public var description: String {
            switch self {
            case .packetTooSmall(let s):     return "Packet too small: \(s) bytes (need 12+ for header)"
            case .unknownTag(let t):         return "Unknown DXV tag: \(t)"
            case .truncatedInput(let n, let a): return "Input truncated: needed \(n), have \(a)"
            case .backRefOutOfRange(let i, let p): return "Back-ref idx=\(i) > pos=\(p) (corrupt stream)"
            case .outputOverflow(let p, let e): return "Output overflow: produced \(p), expected \(e)"
            }
        }
    }

    /// 12-byte header at the start of every DXV packet.
    public struct PacketHeader {
        public let tag: String           // "DXT1", "DXT5", "YCG6", "YG10" (re-ordered from on-disk)
        public let versionMajor: UInt8   // typically 3 for DXV3
        public let versionMinor: UInt8   // typically 0
        public let rawFlag: UInt8        // 0 = compressed (use decompressor), 1 = raw (use as-is)
        public let payloadSize: UInt32   // bytes of compressed/raw payload following the header
        public init(tag: String, versionMajor: UInt8, versionMinor: UInt8, rawFlag: UInt8, payloadSize: UInt32) {
            self.tag = tag
            self.versionMajor = versionMajor
            self.versionMinor = versionMinor
            self.rawFlag = rawFlag
            self.payloadSize = payloadSize
        }
    }

    /// Read the 12-byte header and identify the variant. Caller passes
    /// the FULL packet bytes (header + payload). Header is parsed,
    /// payload sliced and returned for the appropriate decompressor.
    public static func parseHeader(_ packet: Data) throws -> (header: PacketHeader, payload: Data) {
        guard packet.count >= 12 else {
            throw DecodeError.packetTooSmall(size: packet.count)
        }
        let base = packet.startIndex
        // FourCC stored little-endian on disk; reverse to get readable order.
        let tagBytes: [UInt8] = [
            packet[base + 3], packet[base + 2], packet[base + 1], packet[base + 0]
        ]
        let tag = String(bytes: tagBytes, encoding: .ascii) ?? ""
        let header = PacketHeader(
            tag: tag,
            versionMajor: packet[base + 4],
            versionMinor: packet[base + 5],
            rawFlag: packet[base + 6],
            payloadSize: UInt32(packet[base + 8])
                | (UInt32(packet[base + 9]) << 8)
                | (UInt32(packet[base + 10]) << 16)
                | (UInt32(packet[base + 11]) << 24)
        )
        let payloadEnd = 12 + Int(header.payloadSize)
        guard payloadEnd <= packet.count else {
            throw DecodeError.truncatedInput(
                needed: payloadEnd, available: packet.count)
        }
        let payload = packet.subdata(in: (base + 12)..<(base + payloadEnd))
        return (header, payload)
    }

    /// Decompress a DXT1 DXV3 payload to raw DXT1-compressed texture bytes.
    /// The output is exactly `expectedSize` bytes — for DXT1 this is
    /// (width × height) / 2 (4 bits per pixel as DXT1 blocks).
    ///
    /// The decoder is a faithful port of FFmpeg's `dxv_decompress_dxt1`.
    /// I've kept variable names close to the original where it aids
    /// understanding the scheme.
    public static func decompressDXT1(_ payload: Data, expectedSize: Int) throws -> Data {
        var output = Data(count: expectedSize)
        let produced = try output.withUnsafeMutableBytes { outBuf -> Int in
            guard let outBase = outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return try payload.withUnsafeBytes { inBuf -> Int in
                guard let inBase = inBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return try decompressInner(
                    input: inBase, inputSize: payload.count,
                    output: outBase, outputCapacity: expectedSize,
                    elementSize: 2)
            }
        }
        if produced != expectedSize {
            throw DecodeError.outputOverflow(produced: produced, expected: expectedSize)
        }
        return output
    }

    /// Decompress a DXT5 DXV3 payload to raw DXT5-compressed texture bytes.
    /// Output size = width × height (8 bits per pixel as DXT5 blocks).
    ///
    /// DXT5's decompression is significantly more complex than DXT1's
    /// because each 16-byte DXT5 block is treated as 4 four-byte elements
    /// addressed independently, plus there are additional opcode types:
    ///
    ///   - "Long copy" (op 0): reads a length, copies that many DXT5 blocks
    ///     verbatim from `pos-4` (one block back). Used for runs of
    ///     identical-to-prior-block content.
    ///   - "Run-pair" (op 1): reads a run length, copies a pair from
    ///     `pos-4`, and enters "run mode" where subsequent iterations
    ///     just emit pairs from `pos-4` until the run drains.
    ///   - "16-bit back-ref" (op 2): reads a 16-bit offset, copies a pair
    ///     from `pos - (8 + 4*offset)`.
    ///   - "Literal pair" (op 3): reads 8 raw bytes.
    ///
    /// After whichever opcode runs, the decompressor falls into the same
    /// CHECKPOINT-driven nested loop that DXT1 uses, with stride 4.
    ///
    /// Faithful port of FFmpeg's `dxv_decompress_dxt5`.
    public static func decompressDXT5(_ payload: Data, expectedSize: Int) throws -> Data {
        var output = Data(count: expectedSize)
        let produced = try output.withUnsafeMutableBytes { outBuf -> Int in
            guard let outBase = outBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return try payload.withUnsafeBytes { inBuf -> Int in
                guard let inBase = inBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return try decompressDXT5Inner(
                    input: inBase, inputSize: payload.count,
                    output: outBase, outputCapacity: expectedSize)
            }
        }
        if produced != expectedSize {
            throw DecodeError.outputOverflow(produced: produced, expected: expectedSize)
        }
        return output
    }

    /// DXT5 inner decompressor. Stride is always 4 (FFmpeg's `x = 4`).
    /// Output is treated as an array of 4-byte little-endian elements;
    /// 4 elements = 1 DXT5 block.
    private static func decompressDXT5Inner(
        input: UnsafePointer<UInt8>, inputSize: Int,
        output: UnsafeMutablePointer<UInt8>, outputCapacity: Int
    ) throws -> Int {
        var ip = 0
        var pos = 4  // FFmpeg: int pos = 4;
        var run = 0  // run mode state

        let outElemCount = outputCapacity / 4

        // Seed: copy first 4 elements (16 bytes = one DXT5 block) verbatim.
        guard ip + 16 <= inputSize else {
            throw DecodeError.truncatedInput(needed: 16, available: inputSize - ip)
        }
        for k in 0..<16 {
            output[k] = input[ip + k]
        }
        ip += 16

        // CHECKPOINT state.
        var checkpointValue: UInt32 = 0
        var checkpointState: Int = 0
        var idx: Int = 0
        var op: Int = 0

        // Read 4 bytes from input as little-endian UInt32.
        func readLE32() throws -> UInt32 {
            guard ip + 4 <= inputSize else {
                throw DecodeError.truncatedInput(needed: 4, available: inputSize - ip)
            }
            let v = UInt32(input[ip])
                | (UInt32(input[ip + 1]) << 8)
                | (UInt32(input[ip + 2]) << 16)
                | (UInt32(input[ip + 3]) << 24)
            ip += 4
            return v
        }

        func readLE16() throws -> UInt16 {
            guard ip + 2 <= inputSize else {
                throw DecodeError.truncatedInput(needed: 2, available: inputSize - ip)
            }
            let v = UInt16(input[ip]) | (UInt16(input[ip + 1]) << 8)
            ip += 2
            return v
        }

        func readByte() throws -> UInt8 {
            guard ip < inputSize else {
                throw DecodeError.truncatedInput(needed: 1, available: 0)
            }
            let v = input[ip]
            ip += 1
            return v
        }

        // Write 4 bytes at output[pos*4..pos*4+4] from a UInt32 (LE).
        func writeLE32(at pos: Int, value: UInt32) {
            let off = pos * 4
            output[off]     = UInt8(value & 0xFF)
            output[off + 1] = UInt8((value >> 8) & 0xFF)
            output[off + 2] = UInt8((value >> 16) & 0xFF)
            output[off + 3] = UInt8((value >> 24) & 0xFF)
        }

        // Read 4 bytes from output as UInt32 (LE).
        func readLE32FromOutput(at pos: Int) -> UInt32 {
            let off = pos * 4
            return UInt32(output[off])
                | (UInt32(output[off + 1]) << 8)
                | (UInt32(output[off + 2]) << 16)
                | (UInt32(output[off + 3]) << 24)
        }

        // CHECKPOINT(4) — refill word if state==0, dispense one 2-bit op,
        // setting `op` and `idx` per op type. Stride for DXT5 is 4.
        func checkpoint() throws {
            if checkpointState == 0 {
                checkpointValue = try readLE32()
                checkpointState = 16
            }
            op = Int(checkpointValue & 0x3)
            checkpointValue >>= 2
            checkpointState -= 1
            switch op {
            case 1:
                idx = 4  // x = 4
            case 2:
                let b = try readByte()
                idx = (Int(b) + 2) * 4
                if idx > pos {
                    throw DecodeError.backRefOutOfRange(idx: idx, pos: pos)
                }
            case 3:
                let s = try readLE16()
                idx = (Int(s) + 0x102) * 4
                if idx > pos {
                    throw DecodeError.backRefOutOfRange(idx: idx, pos: pos)
                }
            default:
                break
            }
        }

        // Main loop: while pos + 2 <= tex_size/4
        while pos + 2 <= outElemCount {
            if run > 0 {
                // Run mode: emit pair from pos-4, decrement run.
                run -= 1
                let prev1 = readLE32FromOutput(at: pos - 4)
                writeLE32(at: pos, value: prev1)
                pos += 1
                let prev2 = readLE32FromOutput(at: pos - 4)
                writeLE32(at: pos, value: prev2)
                pos += 1
            } else {
                // Pre-checkpoint switch: read raw 2-bit op (NOT via CHECKPOINT).
                if checkpointState == 0 {
                    checkpointValue = try readLE32()
                    checkpointState = 16
                }
                let preOp = Int(checkpointValue & 0x3)
                checkpointValue >>= 2
                checkpointState -= 1

                switch preOp {
                case 0:
                    // Long copy: read length, copy that many blocks (4 elements each) from pos-4.
                    var check = Int(try readByte()) + 1
                    if check == 256 {
                        // Extension: read 16-bit chunks until non-FFFF, accumulate.
                        var probe = 0xFFFF
                        repeat {
                            probe = Int(try readLE16())
                            check += probe
                        } while probe == 0xFFFF
                    }
                    while check > 0 && pos + 4 <= outElemCount {
                        // Copy 4 elements from pos-4.
                        for _ in 0..<4 {
                            let prev = readLE32FromOutput(at: pos - 4)
                            writeLE32(at: pos, value: prev)
                            pos += 1
                        }
                        check -= 1
                    }
                    // FFmpeg uses `continue` here — restart the outer while loop,
                    // bypassing the post-switch CHECKPOINT logic.
                    continue
                case 1:
                    // Set run length. Read run byte; extension via 0xFFFF same as case 0.
                    var r = Int(try readByte())
                    if r == 255 {
                        var probe = 0xFFFF
                        repeat {
                            probe = Int(try readLE16())
                            r += probe
                        } while probe == 0xFFFF
                    }
                    run = r
                    // Then emit a pair from pos-4 (as run mode would, once).
                    let prev1 = readLE32FromOutput(at: pos - 4)
                    writeLE32(at: pos, value: prev1)
                    pos += 1
                    let prev2 = readLE32FromOutput(at: pos - 4)
                    writeLE32(at: pos, value: prev2)
                    pos += 1
                case 2:
                    // Read 16-bit offset, copy pair from pos - (8 + 4*offset).
                    let s = try readLE16()
                    let backIdx = 8 + 4 * Int(s)
                    if backIdx > pos {
                        throw DecodeError.backRefOutOfRange(idx: backIdx, pos: pos)
                    }
                    let prev1 = readLE32FromOutput(at: pos - backIdx)
                    writeLE32(at: pos, value: prev1)
                    pos += 1
                    let prev2 = readLE32FromOutput(at: pos - backIdx)
                    writeLE32(at: pos, value: prev2)
                    pos += 1
                case 3:
                    // Literal pair: read 8 raw bytes.
                    let v1 = try readLE32()
                    writeLE32(at: pos, value: v1)
                    pos += 1
                    let v2 = try readLE32()
                    writeLE32(at: pos, value: v2)
                    pos += 1
                default:
                    break
                }
            }

            // Post-switch CHECKPOINT logic — same nested structure as DXT1
            // but with stride 4. Note: FFmpeg uses the post-CHECKPOINT op
            // for the `if (op)` branch, not the pre-checkpoint op.
            try checkpoint()
            if pos + 2 > outElemCount {
                throw DecodeError.outputOverflow(produced: pos * 4, expected: outputCapacity)
            }

            if op != 0 {
                // Two-element copy from back-reference idx.
                if idx > pos {
                    throw DecodeError.backRefOutOfRange(idx: idx, pos: pos)
                }
                let prev1 = readLE32FromOutput(at: pos - idx)
                writeLE32(at: pos, value: prev1)
                pos += 1
                let prev2 = readLE32FromOutput(at: pos - idx)
                writeLE32(at: pos, value: prev2)
                pos += 1
            } else {
                // Per-element CHECKPOINT decisions.
                try checkpoint()
                let prev1: UInt32
                if op != 0 {
                    if idx > pos {
                        throw DecodeError.backRefOutOfRange(idx: idx, pos: pos)
                    }
                    prev1 = readLE32FromOutput(at: pos - idx)
                } else {
                    prev1 = try readLE32()
                }
                writeLE32(at: pos, value: prev1)
                pos += 1

                try checkpoint()
                let prev2: UInt32
                if op != 0 {
                    if idx > pos {
                        throw DecodeError.backRefOutOfRange(idx: idx, pos: pos)
                    }
                    prev2 = readLE32FromOutput(at: pos - idx)
                } else {
                    prev2 = try readLE32()
                }
                writeLE32(at: pos, value: prev2)
                pos += 1
            }
        }

        return pos * 4
    }

    /// Core decompressor. `elementSize` is 2 for DXT1 (2-byte elements)
    /// or 4 for DXT5 (4-byte elements). The output is treated as an array
    /// of (count = capacity/elementSize) elements; back-references are in
    /// element units, not byte units. `pos` tracks the current element
    /// index we're writing.
    ///
    /// FFmpeg's CHECKPOINT macro pulls 32 bits when the state buffer is
    /// empty, then dispenses 16 successive 2-bit ops from that word.
    /// We implement that as state == count of ops remaining in `value`.
    private static func decompressInner(
        input: UnsafePointer<UInt8>, inputSize: Int,
        output: UnsafeMutablePointer<UInt8>, outputCapacity: Int,
        elementSize: Int
    ) throws -> Int {
        var ip = 0  // input read pointer
        var pos = 0 // current element index in output

        // FFmpeg's dxt1 decompressor copies the FIRST TWO ELEMENTS verbatim
        // before entering the opcode loop. They form the "seed" for back-refs.
        // For dxt1 each element is 4 bytes (a full DXT1 block is 8 bytes,
        // but elements are addressed at 2-byte granularity within blocks
        // when x=2... wait — re-read.)
        //
        // Re-reading FFmpeg dxv.c lines 100-102:
        //     AV_WL32(ctx->tex_data, bytestream2_get_le32(gbc));
        //     AV_WL32(ctx->tex_data + 4, bytestream2_get_le32(gbc));
        // These write 4 bytes each at byte offsets 0 and 4, i.e. the
        // first 8 bytes of output = first 2 DXT1 blocks copied verbatim.
        // The element loop begins at pos=2 in element units where each
        // element is 4 bytes (because x=2 means jump in 2-element steps,
        // and an element pair = 8 bytes = one DXT1 block? Let me re-check).
        //
        // Actually rereading line 105: while (pos + 2 <= ctx->tex_size / 4)
        // tex_size/4 is element count where each element is 4 bytes.
        // pos starts at 2 (line 98). The two seed AV_WL32s wrote elements
        // 0 and 1 (4 bytes each). So elementSize is 4 BYTES at the output
        // level. The "x = 2 for dxt1" means: when op=1, copy from
        // position (pos - 2), i.e. 2 elements back = 8 bytes back. This
        // makes sense: DXT1 blocks pair up as (color, color) and (index,
        // index) is wrong... actually no.
        //
        // DXT1 block layout is 8 bytes: 2-byte color0, 2-byte color1,
        // 4-byte indices. Treating the block as TWO 4-byte halves: half0
        // = colors, half1 = indices. The decoder addresses these halves
        // independently, hence x=2 (skip back 2 halves = 1 block).
        //
        // For DXT5 the block is 16 bytes: 8 bytes alpha info + 8 bytes
        // color info. Treated as four 4-byte quarters; x=4 means skip
        // back 4 quarters = 1 block.
        //
        // So in BOTH cases the output element is 4 BYTES. The `x` (or
        // elementSize as I named it) is the number of those 4-byte
        // elements per "block half-or-quarter pair" that gets skipped.
        // Need to fix my naming: `elementSize` is misleading. Let me
        // rename to `stride`. And the actual byte unit is always 4.
        //
        // RESTART with correct understanding:
        //   - Output is treated as array of UInt32 little-endian elements
        //     (each 4 bytes).
        //   - `stride` = 2 for dxt1 means: when op=1, prev index = pos - 2
        //   - `stride` = 4 for dxt5 means: when op=1, prev index = pos - 4
        //   - First 2 elements (8 bytes) for dxt1, first 4 elements
        //     (16 bytes) for dxt5 are seeded verbatim from input.

        let stride = elementSize  // 2 for dxt1, 4 for dxt5 (in 4-byte elements)
        let outElemCount = outputCapacity / 4

        // Seed: copy the first `stride` 4-byte elements verbatim.
        let seedBytes = stride * 4
        guard ip + seedBytes <= inputSize else {
            throw DecodeError.truncatedInput(
                needed: seedBytes, available: inputSize - ip)
        }
        for k in 0..<seedBytes {
            output[k] = input[ip + k]
        }
        ip += seedBytes
        pos = stride  // element index, not byte index

        // CHECKPOINT state — accumulator dispenses 16 ops per refill.
        var checkpointValue: UInt32 = 0
        var checkpointState: Int = 0

        // Helper to refill the checkpoint accumulator and dispense one op.
        // Mirrors FFmpeg's CHECKPOINT(x) macro.
        func nextOp() throws -> (op: Int, idx: Int) {
            if checkpointState == 0 {
                guard ip + 4 <= inputSize else {
                    throw DecodeError.truncatedInput(
                        needed: 4, available: inputSize - ip)
                }
                checkpointValue = UInt32(input[ip])
                    | (UInt32(input[ip + 1]) << 8)
                    | (UInt32(input[ip + 2]) << 16)
                    | (UInt32(input[ip + 3]) << 24)
                ip += 4
                checkpointState = 16
            }
            let op = Int(checkpointValue & 0x3)
            checkpointValue >>= 2
            checkpointState -= 1
            var idx = 0
            switch op {
            case 0:
                break
            case 1:
                idx = stride
            case 2:
                guard ip + 1 <= inputSize else {
                    throw DecodeError.truncatedInput(
                        needed: 1, available: inputSize - ip)
                }
                let b = Int(input[ip]); ip += 1
                idx = (b + 2) * stride
                if idx > pos {
                    throw DecodeError.backRefOutOfRange(idx: idx, pos: pos)
                }
            case 3:
                guard ip + 2 <= inputSize else {
                    throw DecodeError.truncatedInput(
                        needed: 2, available: inputSize - ip)
                }
                let lo = Int(input[ip]); let hi = Int(input[ip + 1])
                ip += 2
                idx = ((lo | (hi << 8)) + 0x102) * stride
                if idx > pos {
                    throw DecodeError.backRefOutOfRange(idx: idx, pos: pos)
                }
            default: break
            }
            return (op, idx)
        }

        // Helper to write one 4-byte element at output[pos*4..pos*4+4],
        // either by reading 4 bytes from input or by copying from a
        // previously-written element at (pos - idx).
        func writeElement(op: Int, idx: Int) throws {
            guard pos < outElemCount else {
                throw DecodeError.outputOverflow(
                    produced: pos * 4, expected: outputCapacity)
            }
            let dstByte = pos * 4
            if op != 0 {
                let srcByte = dstByte - idx * 4
                guard srcByte >= 0 else {
                    throw DecodeError.backRefOutOfRange(idx: idx, pos: pos)
                }
                output[dstByte]     = output[srcByte]
                output[dstByte + 1] = output[srcByte + 1]
                output[dstByte + 2] = output[srcByte + 2]
                output[dstByte + 3] = output[srcByte + 3]
            } else {
                guard ip + 4 <= inputSize else {
                    throw DecodeError.truncatedInput(
                        needed: 4, available: inputSize - ip)
                }
                output[dstByte]     = input[ip]
                output[dstByte + 1] = input[ip + 1]
                output[dstByte + 2] = input[ip + 2]
                output[dstByte + 3] = input[ip + 3]
                ip += 4
            }
            pos += 1
        }

        // Main decompression loop. FFmpeg's dxt1 decompressor processes
        // pairs: when op != 0, copy two consecutive elements from the
        // back-reference; when op == 0, fall through to handle each
        // element with its OWN op. That nesting matches FFmpeg's source.
        while pos + 2 <= outElemCount {
            let (op1, idx1) = try nextOp()
            if op1 != 0 {
                // Two-element copy from back-reference idx1.
                try writeElement(op: op1, idx: idx1)
                try writeElement(op: op1, idx: idx1)
            } else {
                // Element 1 of the pair — second-level CHECKPOINT.
                let (op2, idx2) = try nextOp()
                try writeElement(op: op2, idx: idx2)
                // Element 2 of the pair — third-level CHECKPOINT.
                let (op3, idx3) = try nextOp()
                try writeElement(op: op3, idx: idx3)
            }
        }

        return pos * 4
    }
}
