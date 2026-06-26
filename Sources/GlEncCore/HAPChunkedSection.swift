// SPDX-License-Identifier: MIT
/*
 * HAPChunkedSection — multi-chunk (0xC_ high-nibble) HAP section writer.
 *
 * v1.2.0 Slice 1. ADDITIVE to the single-section path in
 * `HapFrameEncoder` / `HAPSection.make` — both remain untouched. This
 * type emits the "chunked-Snappy" section form the vendored decoder
 * (`HAPPacketDecoder.decodeChunkedSection`) parses for the 0xC_ high
 * nibble. The decoder is the ground-truth spec; every byte below is
 * written to match what it reads, never a remembered HAP spec.
 *
 * Layout produced (mirrors HAPPacketDecoder.decodeChunkedSection):
 *
 *   outer 0xC_ section (HAPSection.make wraps this payload):
 *     ├─ 0x01 Decode Instructions Container       (HAPSection.make, type 0x01)
 *     │    ├─ 0x02 Chunk Compressor Table — N bytes (0x0A=raw, 0x0B=Snappy)
 *     │    └─ 0x03 Chunk Size Table       — N × uint32 LE (STORED sizes)
 *     ├─ chunk[0] stored bytes
 *     ├─ chunk[1] stored bytes
 *     └─ … chunk[N-1] stored bytes
 *
 * The 0x04 Chunk Offset Table is intentionally omitted: the decoder
 * reconstructs offsets by accumulating the 0x03 sizes and explicitly
 * ignores 0x04. Sub-section order inside 0x01 is 0x02 then 0x03; the
 * decoder walks them in any order.
 *
 * Chunk-size semantics: the 0x03 table holds STORED (on-disk) sizes —
 * the exact byte count the decoder slices from the stream before
 * decompressing per the matching 0x02 compressor byte. So a Snappy
 * chunk records its compressed length; a raw chunk records its raw
 * length.
 *
 * Boundaries: chunks split on BC-block-aligned boundaries (DXT1 = 8
 * bytes/block, DXT5 = 16). The decoder imposes no alignment itself —
 * it simply concatenates the decompressed chunks — but block-aligned
 * splits keep each chunk independently meaningful and match how HAP
 * encoders in the wild chunk. Decoded output is therefore identical
 * for any chunk count (chunk-count invariance).
 */

import Foundation

internal enum HAPChunkedSection {

    /// Per-chunk compressor bytes (match HAPPacketDecoder).
    private static let compressorRaw: UInt8    = 0x0A
    private static let compressorSnappy: UInt8 = 0x0B

    /// Nested metadata section type bytes (match HAPPacketDecoder).
    private static let typeInstructions: UInt8 = 0x01
    private static let typeCompressorTable: UInt8 = 0x02
    private static let typeSizeTable: UInt8 = 0x03

    /// Build a chunked HAP section from a frame's raw BC block stream.
    ///
    /// - Parameters:
    ///   - blocks: the full uncompressed BC/DXT block bytes for the frame.
    ///   - blockSize: bytes per BC block (DXT1 = 8, DXT5 = 16). Split
    ///     boundaries are multiples of this so no chunk bisects a block.
    ///   - chunkCount: requested chunk count (caller guarantees >= 2;
    ///     N == 1 must route the single-section path, not this writer).
    ///     Clamped down to the block count if it exceeds it (can't have
    ///     more chunks than blocks).
    ///   - outerType: the 0xC_ section type (0xCB Hap1 / 0xCE Hap5).
    /// - Returns: a complete HAP section packet (outer header + payload).
    static func make(blocks: Data, blockSize: Int, chunkCount: Int, outerType: UInt8) throws -> Data {
        precondition(blockSize > 0, "HAPChunkedSection: blockSize must be positive")
        precondition(chunkCount >= 2, "HAPChunkedSection: chunkCount must be >= 2 (N==1 uses single-section)")
        precondition(blocks.count % blockSize == 0,
                     "HAPChunkedSection: block stream \(blocks.count) not a multiple of blockSize \(blockSize)")

        let blockCount = blocks.count / blockSize
        // Can't emit more chunks than there are blocks; each chunk holds
        // at least one whole block.
        let n = min(chunkCount, max(1, blockCount))

        // Block split: first n-1 chunks get `base` blocks each, the last
        // takes the remainder (>= base). With n <= blockCount, base >= 1.
        let base = blockCount / n

        var compressors = [UInt8]()
        compressors.reserveCapacity(n)
        var storedSizes = [UInt32]()
        storedSizes.reserveCapacity(n)
        var chunkBytes = [Data]()
        chunkBytes.reserveCapacity(n)

        let blocksBase = blocks.startIndex
        var blockCursor = 0
        for i in 0..<n {
            let chunkBlocks = (i == n - 1) ? (blockCount - blockCursor) : base
            let byteStart = blocksBase + blockCursor * blockSize
            let byteEnd = byteStart + chunkBlocks * blockSize
            let raw = blocks.subdata(in: byteStart..<byteEnd)
            blockCursor += chunkBlocks

            // Snappy-compress the chunk; fall back to raw storage only
            // when Snappy fails to shrink it (the decoder honours 0x0A
            // raw chunks). Keeps output minimal without ever expanding.
            let compressed = SnappyCompressor.compress(raw)
            if compressed.count < raw.count {
                compressors.append(compressorSnappy)
                storedSizes.append(UInt32(compressed.count))
                chunkBytes.append(compressed)
            } else {
                compressors.append(compressorRaw)
                storedSizes.append(UInt32(raw.count))
                chunkBytes.append(raw)
            }
        }

        // 0x01 Decode Instructions Container = 0x02 table ++ 0x03 table.
        let compressorSection = try HAPSection.make(
            payload: Data(compressors), type: typeCompressorTable)
        let sizeSection = try HAPSection.make(
            payload: uint32LEData(storedSizes), type: typeSizeTable)
        var instructions = Data(capacity: compressorSection.count + sizeSection.count)
        instructions.append(compressorSection)
        instructions.append(sizeSection)
        let instructionsSection = try HAPSection.make(
            payload: instructions, type: typeInstructions)

        // Outer payload = 0x01 section ++ all stored chunk bytes.
        var outerPayload = instructionsSection
        for c in chunkBytes { outerPayload.append(c) }

        return try HAPSection.make(payload: outerPayload, type: outerType)
    }

    /// Serialise a [UInt32] as little-endian bytes (matches the
    /// decoder's `readUInt32LEArray`).
    private static func uint32LEData(_ values: [UInt32]) -> Data {
        var out = Data(capacity: values.count * 4)
        for v in values {
            out.append(UInt8( v        & 0xFF))
            out.append(UInt8((v >>  8) & 0xFF))
            out.append(UInt8((v >> 16) & 0xFF))
            out.append(UInt8((v >> 24) & 0xFF))
        }
        return out
    }
}
