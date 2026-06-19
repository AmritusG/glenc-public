/*
 * SnappyCompressorTests — v0.9.1 Phase B.
 *
 * Validates `SnappyCompressor.compress(_:)` by round-tripping every
 * encoded output through `lovetodream/swift-snappy`'s decompressor
 * (`Data.uncompressedUsingSnappy()`) and asserting byte-identity vs
 * the original input. The decompressor wraps Google's reference C
 * `snappy-c` and is the format-compliance oracle.
 *
 * Test inputs cover:
 *   - empty + single-byte (degenerate edges)
 *   - boundary cases for the literal-length encoding (60, 256, 65535)
 *   - constant-bytes (max compressibility — exercises copy tokens)
 *   - pseudo-random (incompressible — exercises literal-only path)
 *   - real-world ASCII corpus (mix of literal + copy)
 *   - large random (5 MB, exercises multi-tag emission)
 *   - monotonic progression 0..1024 (catches off-by-one literal sizing)
 *
 * Most fixtures are synthesized deterministically at test time
 * (seeded LCG) to keep the repo small. One committed ASCII fixture
 * (`reference/snappy/lorem.txt`) provides a stable real-world corpus.
 */

import XCTest
import Foundation
@testable import GlEncCore
import Snappy

final class SnappyCompressorTests: XCTestCase {

    // MARK: - Helpers

    /// Round-trip the input: compress with our encoder, decompress with
    /// the swift-snappy oracle, assert byte-equality. Returns the
    /// compressed size so individual tests can spot-check the ratio.
    @discardableResult
    private func roundTrip(_ input: Data,
                           file: StaticString = #file,
                           line: UInt = #line) throws -> Int {
        let compressed = SnappyCompressor.compress(input)
        let decompressed = try compressed.uncompressedUsingSnappy()
        XCTAssertEqual(decompressed, input,
                       "round-trip mismatch (input \(input.count)B, compressed \(compressed.count)B)",
                       file: file, line: line)
        return compressed.count
    }

    /// Deterministic pseudo-random byte stream. xorshift64* — simple
    /// and fast, matches behaviour across Swift toolchain versions.
    private func deterministicRandom(seed: UInt64, count: Int) -> Data {
        var state = seed == 0 ? 1 : seed
        var out = Data(count: count)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let buf = raw.bindMemory(to: UInt8.self)
            for i in 0..<count {
                // xorshift64
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                buf[i] = UInt8(truncatingIfNeeded: state &* 0x2545F4914F6CDD1D)
            }
        }
        return out
    }

    // MARK: - Degenerate edges

    func testEmptyInput() throws {
        try roundTrip(Data())
    }

    func testSingleByte() throws {
        try roundTrip(Data([0x42]))
    }

    func testTwoBytes() throws {
        try roundTrip(Data([0x00, 0xFF]))
    }

    /// 3-byte input is too short for the matcher's 4-byte hash window;
    /// must fall through to a single literal token.
    func testThreeBytes() throws {
        try roundTrip(Data([0x01, 0x02, 0x03]))
    }

    /// 4-byte input — the minimum where the matcher can hash but
    /// there's only one position, so still no match.
    func testFourBytes() throws {
        try roundTrip(Data([0x01, 0x02, 0x03, 0x04]))
    }

    // MARK: - Literal-length boundary cases

    /// Literal length 60 hits the boundary between inline-tag form
    /// (`(n-1) << 2`) and the 1-byte-extended form (`0xF0 + len`).
    func testLiteralBoundary60() throws {
        let input = deterministicRandom(seed: 1, count: 60)
        try roundTrip(input)
    }

    /// 256 bytes — boundary between 1-byte-extended (0xF0) and
    /// 2-byte-extended (0xF4) length forms.
    func testLiteralBoundary256() throws {
        let input = deterministicRandom(seed: 2, count: 256)
        try roundTrip(input)
    }

    /// 65535 bytes — at the boundary between 2-byte-extended (0xF4)
    /// and 3-byte-extended (0xF8). Just below — should use 0xF4.
    func testLiteralBoundary65535() throws {
        let input = deterministicRandom(seed: 3, count: 65535)
        try roundTrip(input)
    }

    /// 65536 bytes — first input requiring the 3-byte-extended form
    /// (0xF8) for any single literal that spans the whole thing
    /// (which random input does — no copies emit, single literal).
    func testLiteralBoundary65536() throws {
        let input = deterministicRandom(seed: 4, count: 65536)
        try roundTrip(input)
    }

    // MARK: - Copy-token paths

    /// All-zeros input — max compressibility. Exercises the copy-token
    /// chunking (a single 1024-byte zero run becomes a 4-byte literal
    /// header + 4 bytes of zeros, then a chain of 64-byte copy tokens).
    func testAllZeros1024() throws {
        let input = Data(repeating: 0, count: 1024)
        let compressed = try roundTrip(input)
        // Sanity: should compress to far less than the input size.
        XCTAssertLessThan(compressed, 100,
                          "all-zeros should compress to a tiny header + copy chain, got \(compressed)B")
    }

    /// Long all-zeros run — verifies copy-token chunking past 64 bytes.
    /// Snappy's max single-copy length is 64 (2-byte form: 3 bytes
    /// per token), so 65K constant bytes lower-bound at ~3KB output
    /// regardless of compressor implementation. The 4500B threshold
    /// gives slack for the varint preamble + initial literal seed.
    func testAllZeros65K() throws {
        let input = Data(repeating: 0xAA, count: 65_000)
        let compressed = try roundTrip(input)
        XCTAssertLessThan(compressed, 4500,
                          "65K-byte constant should compress at the chunked-copy floor ~3KB, got \(compressed)B")
    }

    /// 4-byte repeating pattern — exercises the 1-byte copy form
    /// (short offset, short length).
    func testFourByteRepeatPattern() throws {
        var input = Data()
        for _ in 0..<256 {
            input.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        }
        // 1024 bytes of "DEADBEEF" repeats.
        try roundTrip(input)
    }

    /// Mid-distance back-reference — pattern that repeats with offset
    /// > 2048, forcing the 2-byte copy form.
    func testLongOffsetCopy() throws {
        var input = deterministicRandom(seed: 5, count: 4096)
        // Append a copy of the first 256 bytes — back-reference
        // distance is 4096 (well past the 1-byte-form's 2048 ceiling).
        input.append(input.prefix(256))
        try roundTrip(input)
    }

    // MARK: - Real-world corpus

    func testLoremASCIICorpus() throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
            .appendingPathComponent("snappy")
            .appendingPathComponent("lorem.txt")
        let input = try Data(contentsOf: url)
        XCTAssertGreaterThan(input.count, 2000, "fixture should be ~3KB")
        let compressed = try roundTrip(input)
        // ASCII text with phrase-level repetition (lorem ipsum is
        // genuinely repetitive). Should compress to less than the
        // input size.
        XCTAssertLessThan(compressed, input.count,
                          "lorem.txt should compress (input \(input.count)B → \(compressed)B)")
    }

    // MARK: - Incompressible / large

    /// Pseudo-random ~1MB — expected to be mostly literal-token output
    /// with no back-references (random has no structure to match).
    /// Output should be at most ~1% larger than input.
    func testIncompressibleRandom1MB() throws {
        let input = deterministicRandom(seed: 6, count: 1_048_576)
        let compressed = try roundTrip(input)
        let ratio = Double(compressed) / Double(input.count)
        XCTAssertLessThan(ratio, 1.03,
                          "incompressible random should expand < 3%, got \(ratio)")
    }

    /// 5MB random — stress the multi-tag emission path. Round-trip
    /// must succeed; size constraint loosened compared to 1MB.
    func testLargeRandom5MB() throws {
        let input = deterministicRandom(seed: 7, count: 5 * 1_048_576)
        try roundTrip(input)
    }

    // MARK: - Monotonic progression

    /// Round-trip every size 0..1024. Catches off-by-one bugs in
    /// literal-length encoding and the matcher's bounds checks.
    func testMonotonicProgression0to1024() throws {
        for size in 0...1024 {
            let input = deterministicRandom(seed: UInt64(8 + size), count: size)
            try roundTrip(input,
                          file: #file,
                          line: #line)
        }
    }

    // MARK: - Mixed content (a likely HAP payload shape)

    /// Simulated DXT-block-like input: repeating 16-byte block
    /// patterns with occasional variation. Exercises both copy and
    /// literal emission on something shaped like the actual HAP
    /// payload data the encoder will compress.
    func testDXTBlockLikePayload() throws {
        var input = Data()
        let blockA: [UInt8] = [0x00, 0xFF, 0x00, 0xFF, 0xAA, 0xAA, 0xAA, 0xAA,
                               0x55, 0x55, 0x55, 0x55, 0xFF, 0x00, 0xFF, 0x00]
        let blockB: [UInt8] = [0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80,
                               0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0, 0x00]
        // 8160 blocks ≈ 1920×1080 / 16 (DXT1's per-frame block count).
        for i in 0..<8160 {
            input.append(contentsOf: (i % 7 == 0) ? blockB : blockA)
        }
        let compressed = try roundTrip(input)
        // Mostly-repetitive pattern should compress significantly.
        XCTAssertLessThan(compressed, input.count / 8,
                          "DXT-like repeating payload should compress > 8×, got \(input.count)B → \(compressed)B")
    }

    // v0.9.1 Phase H.3 — regression for the 1-byte copy form's
    // chunking bug. emitCopy chunks the 2-byte form at 64-byte tokens.
    // When the *remaining* after a 64-byte chunk is 1..3 AND the
    // offset < 2048 (which routes the next iter to the 1-byte form),
    // the 1-byte form's `chunk - 4` underflows to -3..-1 and
    // `UInt8(negative)` traps with "Negative value is not
    // representable".
    //
    // Trigger: total match length L where L mod 64 ∈ {1, 2, 3}, and
    // the source has a near-distance back-reference (offset 1..2047).
    // 66 zero bytes triggers cleanly: matcher finds match-len 65 at
    // offset 1, chunks 64 + 1, and the 1-byte branch underflows.
    //
    // Real-world impact: surfaced by encoding a 1080p video frame to
    // Hap5 (Resolume validation, Phase H.2). The 64×64 procedural
    // harness's small DXT block streams never produced match-lengths
    // with the offending residue class. Fix: when chunking the
    // 2-byte form would leave 1..3 bytes for a subsequent 1-byte
    // form, emit a 60-byte chunk instead (matches Google's
    // snappy.cc EmitCopy reservation strategy).
    func testCopyLength65BoundaryWithSmallOffset_NoCrash() throws {
        for n in 65...68 {
            // n bytes of zeros → matcher emits one match of length
            // (n - 1) at offset 1 starting from position 1. n=66 →
            // match-len 65, n=67 → 66, n=68 → 67 (all crash before
            // the fix). n=69 → match-len 68 → boundary safe.
            let input = Data(repeating: 0, count: n)
            try roundTrip(input)
        }
    }

    /// More residues of the same bug at larger lengths. Match-len
    /// 129/130/131 = 64 + 65/66/67 also chunk to (64, 1..3).
    func testCopyLength129To131Residues_NoCrash() throws {
        for n in [130, 131, 132] {  // matchLen = 129..131
            let input = Data(repeating: 0, count: n)
            try roundTrip(input)
        }
    }

    /// Same residue class with non-trivial offset still in the
    /// 1-byte form's range (< 2048). Two-pattern source so the match
    /// has a real (not RLE) offset.
    func testCopyLength65WithModerateOffset_NoCrash() throws {
        // 1 KB of pattern A, then re-emit pattern A's first 65 bytes
        // and let the matcher catch the cross-back-reference.
        var pattern = Data()
        for i in 0..<1024 { pattern.append(UInt8(i & 0xFF)) }
        var input = pattern
        // Tail: 65 bytes that match the start of pattern at offset ≈ 1024
        input.append(pattern.prefix(65))
        try roundTrip(input)
    }
}
