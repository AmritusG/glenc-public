// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Encoder-side derivation of FFmpeg libavcodec/dxv.c decoder routines.
// Original C: Copyright (C) 2015 Vittorio Giovara; (C) 2018 Paul B Mahol.
// Licensed under LGPL-2.1-or-later; this Swift derivation preserves that
// license. See THIRD-PARTY-NOTICES.md.
/*
 * DXVHQOpcodeWriter — encode the opcode stream consumed by FFmpeg's
 * `dxv_decompress_opcodes` (libavcodec/dxv.c lines 274..298).
 *
 * The decoder reads a 1-byte flag (`first_byte & 3`) to pick one of
 * three encodings:
 *
 *     flag & 3 == 0  raw:        flag byte then `op_size` verbatim bytes
 *     flag & 3 == 1  byte-fill:  flag byte then 1 byte, memset op_size times
 *     flag & 3 >= 2  Huffman:    packed ltable + canonical Huffman bitstream
 *
 * Pass C empirically observed reference encoders (Alley + AME) using
 * Huffman exclusively on testsrc2 (180/180 streams). The decoder
 * accepts all three modes — GlEnc Phase 4A v0.4.0 takes the simpler
 * route:
 *
 *   - byte-fill if the stream is a single unique value (common for
 *     short cocg chunks of pure op-1 RLE between explicit groups).
 *   - raw otherwise.
 *
 * Huffman is a strict file-size optimization (Pass C saw ~50 % byte
 * compression on opcode streams). Deferred to v0.4.1 since the gate
 * for v0.4.0 is "Resolume plays the output" + "within 2x Alley on
 * real content" — both achievable with raw-mode opcode encoding given
 * Pass C's ~25 K opcodes per frame (raw cost ≈ 25 KB / frame vs
 * Huffman ≈ 12 KB / frame).
 */

import Foundation

public enum DXVHQOpcodeWriter {

    /// Encode an opcode byte stream for one yo/cocg sub-stream.
    /// Returns the encoded bytes (flag byte + payload).
    /// `opcodes.count` is the `op_size` the decoder expects.
    public static func encodeStream(opcodes: [UInt8]) -> Data {
        if opcodes.isEmpty {
            // Zero-length stream → emit raw mode with no body.
            return Data([0x00])
        }

        // Byte-fill if uniform.
        var uniform = true
        let first = opcodes[0]
        for b in opcodes where b != first {
            uniform = false
            break
        }
        if uniform {
            // flag = 0x01, then 1 byte (the repeating value), then
            // decoder memsets op_size copies into dst.
            return Data([0x01, first])
        }

        // Raw mode: flag = 0x00, followed by op_size opcode bytes.
        var out = Data(capacity: 1 + opcodes.count)
        out.append(0x00)
        out.append(contentsOf: opcodes)
        return out
    }
}
