/*
 * Phase 3A.5 — outer-op-1 (run-init) tests for compressDXT5.
 *
 *  - testFlatAlphaRunUsesOpcodeOne: synthesize a BC3 buffer where every
 *    block has identical alpha + identical color. Encode via the LZ
 *    writer, decode through GlanceCore, and verify the LZ payload is
 *    drastically smaller than literals-everywhere (proves op-1 fired).
 *  - testRunCountExtensionEncoding: build a BC3 buffer with > 255
 *    consecutive identical-alpha blocks. Verify the run-count extension
 *    (byte 0xFF + le16 chunks) round-trips correctly.
 *  - testRunInterleavedWithDifferentAlpha: alternating runs and
 *    non-matching blocks. Round-trip must preserve byte-identity.
 *  - testFirstBlockNeverInRun: block 1 is the earliest possible op-1
 *    (block 0 is the seed). If block 0 == block 1, op-1 should fire at
 *    block 1; otherwise Strategy A's outer-op-2/3 path takes over.
 *
 * All tests round-trip through `DXVPacketDecoder.decompressDXT5` (the
 * faithful FFmpeg port) and compare bytes 1:1 against the encoder's
 * own BC3 buffer — same shape as Phase 3A's
 * `testLZRoundTripPreservesBC3Bytes`.
 */

import XCTest
@testable import GlEncCore
import GlanceCore

final class DXVLZWriterDXT5OpcodeOneTests: XCTestCase {

    /// 256 BC3 blocks all (a0=128, a1=128, indices=0, c0=0, c1=0,
    /// mask=0xAAAAAAAA). Encoded payload should be tiny (one op-1 emit
    /// + a few op-1 combo emits for the color half) — Strategy A would
    /// have produced ~256*16 = 4 KB literals.
    func testFlatAlphaRunUsesOpcodeOne() throws {
        let blockCount = 256
        let bc3 = uniformBC3Buffer(blockCount: blockCount,
                                   alphaA0: 128, alphaA1: 128,
                                   colorC0: 0, colorC1: 0,
                                   colorMask: 0xAAAAAAAA)

        let writer = DXVLZWriter()
        let payload = bc3.withUnsafeBufferPointer { buf in
            writer.compressDXT5(tex: buf.baseAddress!, count: buf.count)
        }

        // Round-trip: decompress and compare.
        let decoded = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: bc3.count)
        XCTAssertEqual(Array(decoded), bc3,
                       "LZ round-trip must preserve all \(blockCount) BC3 blocks")

        // Strategy A literals-everywhere ≈ block_count * 17 bytes; with
        // op-1 + combo it should drop to under 1 % of that. Generous
        // ceiling at 256 bytes for 256 identical blocks.
        XCTAssertLessThan(payload.count, 256,
                          "expected op-1 + combo to compress 256 identical blocks to under 256 bytes; got \(payload.count)")
        // And the payload must include at least the seed (16 bytes) so a
        // bug that drops to zero would also fail.
        XCTAssertGreaterThan(payload.count, 16)
    }

    /// 1000 identical-alpha blocks force the run-count extension path
    /// (byte 0xFF + le16 = (1000 - 1 - 255)). Round-trip preserves bytes.
    func testRunCountExtensionEncoding() throws {
        let blockCount = 1000
        let bc3 = uniformBC3Buffer(blockCount: blockCount,
                                   alphaA0: 64, alphaA1: 64,
                                   colorC0: 0xF800, colorC1: 0xF800,
                                   colorMask: 0xAAAAAAAA)
        let writer = DXVLZWriter()
        let payload = bc3.withUnsafeBufferPointer { buf in
            writer.compressDXT5(tex: buf.baseAddress!, count: buf.count)
        }
        let decoded = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: bc3.count)
        XCTAssertEqual(Array(decoded), bc3,
                       "extension-encoded run must round-trip byte-perfectly")
    }

    /// Interleave runs and non-matching blocks — encoder must flush each
    /// run cleanly and pick up Strategy A's outer-op-2/3 path on the
    /// non-matching block.
    func testRunInterleavedWithDifferentAlpha() throws {
        // Layout: [10 × α=128 blocks] + [1 × α=64 block] + [10 × α=128 blocks]
        // + [1 × α=200 block] + [10 × α=128 blocks]
        var bc3: [UInt8] = []
        bc3.append(contentsOf: blocks(count: 10, alpha: 128))
        bc3.append(contentsOf: blocks(count: 1, alpha: 64))
        bc3.append(contentsOf: blocks(count: 10, alpha: 128))
        bc3.append(contentsOf: blocks(count: 1, alpha: 200))
        bc3.append(contentsOf: blocks(count: 10, alpha: 128))
        let writer = DXVLZWriter()
        let payload = bc3.withUnsafeBufferPointer { buf in
            writer.compressDXT5(tex: buf.baseAddress!, count: buf.count)
        }
        let decoded = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: bc3.count)
        XCTAssertEqual(Array(decoded), bc3,
                       "interleaved runs + breaks must round-trip byte-perfectly")
    }

    /// Block 0 is always the seed (literal 16 bytes). Block 1 can use op-1
    /// if its alpha matches block 0's alpha — earliest possible op-1
    /// emission.
    func testFirstBlockUsesOpcodeOneWhenAlphaMatchesSeed() throws {
        // Two identical blocks. Block 0 = seed, block 1 = op-1 (run = 0,
        // covers exactly 1 block).
        let bc3 = uniformBC3Buffer(blockCount: 2,
                                   alphaA0: 200, alphaA1: 200,
                                   colorC0: 0, colorC1: 0,
                                   colorMask: 0xAAAAAAAA)
        let writer = DXVLZWriter()
        let payload = bc3.withUnsafeBufferPointer { buf in
            writer.compressDXT5(tex: buf.baseAddress!, count: buf.count)
        }
        let decoded = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: bc3.count)
        XCTAssertEqual(Array(decoded), bc3)
        // Tight cap: seed (16) + opdword (4) + run byte (1) ≤ 25 bytes
        // even with worst-case overhead.
        XCTAssertLessThan(payload.count, 32,
                          "2 identical blocks should fit in well under 32 bytes")
    }

    // MARK: - BC3 buffer synthesis

    private func uniformBC3Buffer(blockCount: Int,
                                  alphaA0: UInt8, alphaA1: UInt8,
                                  colorC0: UInt16, colorC1: UInt16,
                                  colorMask: UInt32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: blockCount * 16)
        for b in 0..<blockCount {
            let off = b * 16
            // BC4 alpha: a0, a1, then 6 zero bytes (all-index-0).
            out[off + 0] = alphaA0
            out[off + 1] = alphaA1
            // BC1 color: c0 LE16, c1 LE16, mask LE32.
            out[off + 8]  = UInt8(colorC0 & 0xFF)
            out[off + 9]  = UInt8((colorC0 >> 8) & 0xFF)
            out[off + 10] = UInt8(colorC1 & 0xFF)
            out[off + 11] = UInt8((colorC1 >> 8) & 0xFF)
            out[off + 12] = UInt8(colorMask & 0xFF)
            out[off + 13] = UInt8((colorMask >> 8) & 0xFF)
            out[off + 14] = UInt8((colorMask >> 16) & 0xFF)
            out[off + 15] = UInt8((colorMask >> 24) & 0xFF)
        }
        return out
    }

    /// Build `count` BC3 blocks with the given (a0=a1=alpha) BC4 block
    /// + a deterministic per-block color block (so non-matching blocks
    /// don't accidentally combo-hit each other).
    private func blocks(count: Int, alpha: UInt8) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 16)
        for i in 0..<count {
            // Alpha portion
            out.append(alpha)
            out.append(alpha)
            out.append(contentsOf: [0, 0, 0, 0, 0, 0])
            // Color portion — vary c0 per (alpha, i) so blocks aren't
            // accidentally fully identical (which would also trigger
            // color-combo path; we want to isolate op-1 as the only
            // compression).
            let c: UInt16 = UInt16(alpha) &+ UInt16(i & 0xFF)
            out.append(UInt8(c & 0xFF))
            out.append(UInt8((c >> 8) & 0xFF))
            out.append(UInt8((c &+ 1) & 0xFF))
            out.append(UInt8(((c &+ 1) >> 8) & 0xFF))
            out.append(0xAA); out.append(0xAA); out.append(0xAA); out.append(0xAA)
        }
        return out
    }
}
