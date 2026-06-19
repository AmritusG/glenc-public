/*
 * HapMEncoderTests — v0.9.3 Phase B.
 *
 * Validates HapMEncoder end-to-end. HapM is the Resolume-loadable
 * HAP + alpha format: outer 0x0D section wrapping HapY (0xBF) + HapA
 * (0xB1) inner sections, each independently Snappy-compressed.
 *
 * Coverage:
 *   - 1080p construction (mandatory per the v0.9.1 H.3 real-frame-size
 *     standing rule).
 *   - Structural assertions: outer 0x0D, inner #0 = 0xBF (HapY first
 *     per Q2), inner #1 = 0xB1 (HapA second), outer short-form derived
 *     from first principles (both inner Snappy streams well under the
 *     16 MB single-section ceiling at 1080p).
 *   - Round-trip via inline HapY-inverse + inline BC4 unpack: encode
 *     procedural frames → demux → decompose each inner section →
 *     decode → measure RGB PSNR + alpha max-Δ vs the source.
 *   - Q3 opaque-source case: an opaque-alpha frame produces a valid
 *     HapM (both inner sections present) and decodes to opaque
 *     output. No special-casing in the encoder.
 *   - Reference fixture: demuxes reference/hapm/test-hapm.mov,
 *     asserts its outer 0x0D + HapY-kind / HapA-kind inner section
 *     types (the fixture happens to use chunked-Snappy 0xCF / 0xC1
 *     forms, which are spec-equivalent to the 0xBF / 0xB1 forms
 *     HapMEncoder emits). The fixture was verified before commit to
 *     be a genuine HapM via a scratch script (not Finder CMD+I).
 *     Round-trip is NOT performed on the fixture because chunked-
 *     Snappy decode isn't part of GlanceCore v0.5.0's public API
 *     (lands post-v0.5.0); the structural assertion is what gives
 *     the fixture diagnostic value here. Round-trip is covered
 *     against our own encoder output (which emits the simpler
 *     single-Snappy form per Q1).
 *
 * Mirrors HapYEncoderTests / HapAEncoderTests' shape — inline AtomTree
 * + section header parser + BC4 unpack + HapY inverse so the test
 * target stays GlanceCore-v0.5.0-pinned. CPURender.cgImageFromDXT (.dxt5)
 * is the one bit of GlanceCore v0.5.0 API we lean on for BC3 decode
 * — same pattern HAPValidationHarnessTests uses.
 */

import XCTest
import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import GlanceCore
@testable import GlEncCore
import Snappy

@MainActor
final class HapMEncoderTests: XCTestCase {

    // MARK: - Frame synthesis

    /// BGRA frame at (width, height). RGB carries a diagonal gradient
    /// (low entropy, friendly for the Snappy match finder + meaningful
    /// for HapY's per-block scale selection); alpha given by `alphaFn`.
    private func makeFrame(
        width: Int, height: Int,
        alphaInfo: CGImageAlphaInfo = .last,
        alphaFn: (Int, Int) -> UInt8
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "HapMTest", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                // BGRA: B, G, R, A.
                p[0] = UInt8((x &+ y) & 0xFF)              // B
                p[1] = UInt8(((x &* 2) &+ y) & 0xFF)       // G
                p[2] = UInt8((x &+ (y &* 2)) & 0xFF)       // R
                p[3] = alphaFn(x, y)
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero,
                          alphaInfo: alphaInfo)
    }

    private func halfAlphaFrame(width: Int, height: Int) throws -> PixelFrame {
        try makeFrame(width: width, height: height) { _, y in
            y < height / 2 ? 0xFF : 0x00
        }
    }

    private func opaqueFrame(width: Int, height: Int) throws -> PixelFrame {
        try makeFrame(width: width, height: height) { _, _ in 0xFF }
    }

    // MARK: - 1. Construction + structural assertions at 1080p

    /// 1920×1080 HapM encode, single frame.
    ///
    /// Structural expectations derived FROM SPEC, not from encoder
    /// output (standing rule):
    ///
    /// - Outer section type byte: 0x0D (HapM wrapper, per
    ///   HAPM_PLAN.md §1.2 + GlanceCore HEAD HAPHQDecoder.swift:166-170).
    /// - Inner section order: HapY first (0xBF), HapA second (0xB1)
    ///   per Q2 locked decision.
    /// - Outer section header form: SHORT (4 bytes). Reasoning: at
    ///   1920×1080 the BC3 stream is 480×270×16 = 2,073,600 B raw
    ///   and the BC4 stream is 480×270×8 = 1,036,800 B raw. Snappy
    ///   compression typically shrinks these on procedural-gradient
    ///   content. Even worst-case (no compression), the sum is ~3 MB,
    ///   well under the 16 MB short-form ceiling. → outer header
    ///   must be 4 bytes (3-byte length + 1-byte type), NOT 8.
    func testHapM_1080p_StructuralAssertions() throws {
        let w = 1920, h = 1080
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapm-1080p-struct-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try halfAlphaFrame(width: w, height: h)
        let encoder = try HapMEncoder(width: w, height: h, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        XCTAssertGreaterThan(data.count, 100, "HapM file should have non-trivial size")

        // stsd FourCC must be "HapM".
        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let stsd = findAtom(tree.children,
                                  path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else {
            return XCTFail("stsd not found")
        }
        let stsdInner = stsd.children
        XCTAssertNotNil(stsdInner.first(where: { $0.type == "HapM" }),
                        "HapM sample entry missing from stsd; got \(stsdInner.map { $0.type })")

        // Pull the first sample, parse outer header.
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let outerHeader = try parseHAPSectionHeader(packet: firstSample)

        XCTAssertEqual(outerHeader.sectionType, 0x0D,
                       "outer section type must be 0x0D (HapM wrapper)")
        XCTAssertEqual(outerHeader.payloadOffset, 4,
                       "outer header must be short-form (4 bytes) — combined inner Snappy streams at 1080p sit well under the 16 MB short-form ceiling")
        XCTAssertGreaterThan(outerHeader.payloadLength, 0)

        // Walk the outer payload — first inner must be HapY (0xBF),
        // second must be HapA (0xB1), per Q2 order.
        let outerPayload = firstSample.subdata(
            in: outerHeader.payloadOffset..<(outerHeader.payloadOffset + outerHeader.payloadLength))

        let inner0 = try parseHAPSectionHeader(packet: outerPayload)
        XCTAssertEqual(inner0.sectionType, 0xBF,
                       "inner #0 must be 0xBF (HapY, Snappy-compressed scaled YCoCg DXT5) — Q2 order")

        let inner1Start = inner0.payloadOffset + inner0.payloadLength
        XCTAssertLessThan(inner1Start, outerPayload.count,
                          "inner #1 must follow inner #0 inside the outer payload")
        let inner1Region = outerPayload.subdata(in: inner1Start..<outerPayload.count)
        let inner1 = try parseHAPSectionHeader(packet: inner1Region)
        XCTAssertEqual(inner1.sectionType, 0xB1,
                       "inner #1 must be 0xB1 (HapA, Snappy-compressed RGTC1 alpha) — Q2 order")

        // Outer payload exactly contains both inner sections.
        let inner1End = inner1Start + inner1.payloadOffset + inner1.payloadLength
        XCTAssertEqual(inner1End, outerPayload.count,
                       "outer payload should hold exactly the two inner sections with no trailing bytes")
    }

    // MARK: - 2. Round-trip via inline HapM decode at 1080p

    /// Encode a 1080p frame, round-trip through inline HapM decode
    /// (parse outer 0x0D → Snappy-decompress both inner sections →
    /// CPURender.cgImageFromDXT for BC3 → HapY inverse for RGB +
    /// inline BC4 unpack for alpha), measure quality vs source.
    ///
    /// Tolerance derivation (matches HAPValidationHarnessTests precedent):
    ///   - RGB PSNR ≥ 23 dB. HapY's procedural-content threshold in the
    ///     existing harness is also 23 dB (HAPValidationHarnessTests.swift:203);
    ///     HapM's RGB is HapY's RGB by definition, so the same gate applies.
    ///   - Alpha max |Δ| ≤ 8 LSB. BC4 single-channel decodes near-lossless
    ///     on smooth gradients; HapA's harness expects ≥ 40 dB PSNR
    ///     (line 182). On this content, max-delta-per-pixel ≤ 8 LSB
    ///     is a substantially looser equivalent gate.
    func testHapM_1080p_RoundTripViaInlineDecode() throws {
        let w = 1920, h = 1080
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapm-1080p-rt-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try halfAlphaFrame(width: w, height: h)
        let encoder = try HapMEncoder(width: w, height: h, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        // Extract the encoded outer packet.
        let data = try Data(contentsOf: tmp)
        let tree = AtomTree(data: data, range: 0..<data.count)
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)

        // Decode via inline HapM decoder.
        let decodedRGBA = try decodeHapMOuterSingleSnappy(
            outerPacket: firstSample, width: w, height: h)
        XCTAssertEqual(decodedRGBA.count, w * h * 4,
                       "decodedRGBA should be width*height*4 bytes")

        // Compare against source. Source PixelFrame.bgraBytes is BGRA;
        // decodedRGBA is RGBA. Swap B↔R when comparing.
        let srcBGRA = frame.bgraBytes()
        var sumSqRGB: Double = 0
        var maxAlphaDelta = 0
        srcBGRA.withUnsafeBytes { srcRaw in
            let src = srcRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            decodedRGBA.withUnsafeBufferPointer { dstBuf in
                let dst = dstBuf.baseAddress!
                for i in 0..<(w * h) {
                    let sR = Int(src[i * 4 + 2])
                    let sG = Int(src[i * 4 + 1])
                    let sB = Int(src[i * 4 + 0])
                    let sA = Int(src[i * 4 + 3])
                    let dR = Int(dst[i * 4 + 0])
                    let dG = Int(dst[i * 4 + 1])
                    let dB = Int(dst[i * 4 + 2])
                    let dA = Int(dst[i * 4 + 3])
                    let dr = sR - dR, dg = sG - dG, db = sB - dB
                    sumSqRGB += Double(dr * dr + dg * dg + db * db)
                    let da = abs(sA - dA)
                    if da > maxAlphaDelta { maxAlphaDelta = da }
                }
            }
        }
        // PSNR over RGB (3 channels × pixel count samples).
        let mseRGB = sumSqRGB / Double(3 * w * h)
        let psnrRGB = mseRGB <= 0 ? .infinity : 10.0 * log10(255.0 * 255.0 / mseRGB)
        print("[HapMEncoderTests] 1080p RGB PSNR: \(psnrRGB) dB; alpha max |Δ|: \(maxAlphaDelta) LSB")
        XCTAssertGreaterThan(psnrRGB, 23.0,
                             "1080p HapM RGB PSNR \(psnrRGB) below 23 dB gate")
        XCTAssertLessThanOrEqual(maxAlphaDelta, 8,
                                 "1080p HapM alpha max |Δ| \(maxAlphaDelta) exceeds 8 LSB gate")
    }

    // MARK: - 3. Q3: opaque source produces a valid HapM (no rejection)

    /// Q3 locked: HapM does NOT reject opaque sources. The HapA inner
    /// section runs normally — BC4 collapses alpha=255 to a single
    /// constant endpoint per block, the encoder emits a structurally
    /// normal HapM, and the decoded output reads opaque.
    func testHapM_OpaqueSource_ProducesValidHapMWithOpaqueAlpha() throws {
        let w = 256, h = 256
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapm-opaque-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try opaqueFrame(width: w, height: h)
        let encoder = try HapMEncoder(width: w, height: h, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        let tree = AtomTree(data: data, range: 0..<data.count)
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)

        // Structural: outer 0x0D + both inner sections present.
        let outer = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(outer.sectionType, 0x0D,
                       "opaque-source HapM must still wrap in 0x0D (no fallback to HapY)")
        let outerPayload = firstSample.subdata(
            in: outer.payloadOffset..<(outer.payloadOffset + outer.payloadLength))
        let inner0 = try parseHAPSectionHeader(packet: outerPayload)
        XCTAssertEqual(inner0.sectionType, 0xBF,
                       "opaque-source HapM must still carry an inner HapY section")
        let inner1Region = outerPayload.subdata(
            in: (inner0.payloadOffset + inner0.payloadLength)..<outerPayload.count)
        let inner1 = try parseHAPSectionHeader(packet: inner1Region)
        XCTAssertEqual(inner1.sectionType, 0xB1,
                       "opaque-source HapM must still carry an inner HapA section (Q3: no rejection, no fallback)")

        // Decode and verify alpha plane reads back opaque.
        let decodedRGBA = try decodeHapMOuterSingleSnappy(
            outerPacket: firstSample, width: w, height: h)
        XCTAssertEqual(decodedRGBA.count, w * h * 4)

        var minAlpha: UInt8 = 0xFF
        decodedRGBA.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            for i in 0..<(w * h) {
                let a = p[i * 4 + 3]
                if a < minAlpha { minAlpha = a }
            }
        }
        // BC4 on constant-α=255 collapses to a single endpoint per
        // block; the decoded value should be 255 across every pixel.
        // Tolerate ≤ 1 LSB to absorb any rounding inside BC4's
        // palette-index pass.
        XCTAssertGreaterThanOrEqual(minAlpha, 254,
                                    "opaque-source HapM should decode to ≥ 254 alpha everywhere; got min \(minAlpha)")
    }

    // MARK: - 4. Reference fixture structural assertion

    /// Demux the committed HapM reference fixture and verify its
    /// structure matches genuine HapM. The fixture was produced by
    /// Resolume and verified before commit via a scratch script
    /// (NOT Finder CMD+I) to be:
    ///   - stsd FourCC "HapM"
    ///   - outer section type 0x0D
    ///   - inner #0 type 0xCF (chunked-Snappy HapY)
    ///   - inner #1 type 0xC1 (chunked-Snappy HapA)
    ///   - inner order: HapY-kind first, HapA-kind second
    ///
    /// Chunked-Snappy (0xCF / 0xC1) is the in-the-wild form HapM files
    /// commonly use, distinct from the single-Snappy (0xBF / 0xB1)
    /// form HapMEncoder ships per Q1. Both are spec-equivalent and
    /// Glance's full HAPPacketDecoder accepts both — but chunked-
    /// Snappy decode isn't in v0.5.0's public API surface, so this
    /// test asserts STRUCTURE only on the fixture. Round-trip is
    /// covered against our own encoder output above.
    func testReferenceFixture_StructuralAssertions() throws {
        // Find <repo>/reference/hapm/test-hapm.mov.
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent() // GlEncTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // <repo>
        let fixtureURL = repoRoot
            .appendingPathComponent("reference")
            .appendingPathComponent("hapm")
            .appendingPathComponent("test-hapm.mov")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("reference/hapm/test-hapm.mov fixture not present; skipping")
        }

        let data = try Data(contentsOf: fixtureURL)
        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let stsd = findAtom(tree.children,
                                  path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else {
            return XCTFail("stsd not found in fixture")
        }
        XCTAssertNotNil(stsd.children.first(where: { $0.type == "HapM" }),
                        "fixture stsd FourCC must be HapM")

        // Pull first sample, parse outer header.
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let outer = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(outer.sectionType, 0x0D,
                       "fixture outer section type must be 0x0D")

        // Walk inner sections. Accept ANY known HapY type byte
        // (0xAF / 0xBF / 0xCF) and ANY known HapA type byte
        // (0xA1 / 0xB1 / 0xC1) — the fixture happens to be chunked-
        // Snappy (0xCF / 0xC1) but these are spec-equivalent forms.
        let outerPayload = firstSample.subdata(
            in: outer.payloadOffset..<(outer.payloadOffset + outer.payloadLength))
        let inner0 = try parseHAPSectionHeader(packet: outerPayload)
        let hapYTypes: Set<UInt8> = [0xAF, 0xBF, 0xCF]
        let hapATypes: Set<UInt8> = [0xA1, 0xB1, 0xC1]
        XCTAssertTrue(hapYTypes.contains(inner0.sectionType),
                      String(format: "fixture inner #0 must be a HapY-kind section; got 0x%02X", inner0.sectionType))

        let inner1Region = outerPayload.subdata(
            in: (inner0.payloadOffset + inner0.payloadLength)..<outerPayload.count)
        let inner1 = try parseHAPSectionHeader(packet: inner1Region)
        XCTAssertTrue(hapATypes.contains(inner1.sectionType),
                      String(format: "fixture inner #1 must be a HapA-kind section; got 0x%02X", inner1.sectionType))

        // Width/height from the stsd VisualSampleEntry. Layout
        // (post the 8-byte size+FourCC entry header that AtomTree
        // strips into `bodyRange.lowerBound`):
        //   0..6   reserved (6 B)
        //   6..8   data_reference_index (2 B)
        //   8..24  predefined/reserved (16 B)
        //   24..26 width (2 B UInt16BE)
        //   26..28 height (2 B UInt16BE)
        // HAPDemuxer.parseStsd reads at firstEntry+32 where firstEntry
        // is the stsd-body offset 8 to the first entry's SIZE field —
        // so HAPDemuxer's "+32" lands at sample-entry offset 32, but
        // since our AtomTree strips the 8-byte entry header into
        // bodyRange, our equivalent offset is 32 - 8 = 24.
        guard let hapMEntry = stsd.children.first(where: { $0.type == "HapM" }) else {
            return XCTFail("HapM entry missing in stsd")
        }
        let entryBodyStart = hapMEntry.bodyRange.lowerBound
        let widthAtomBE = (Int(data[entryBodyStart + 24]) << 8) | Int(data[entryBodyStart + 25])
        let heightAtomBE = (Int(data[entryBodyStart + 26]) << 8) | Int(data[entryBodyStart + 27])
        XCTAssertGreaterThan(widthAtomBE, 0, "fixture width must be > 0; got \(widthAtomBE)")
        XCTAssertGreaterThan(heightAtomBE, 0, "fixture height must be > 0; got \(heightAtomBE)")
        // The committed fixture is the Resolume export at 512×288.
        XCTAssertEqual(widthAtomBE, 512, "fixture width should be 512 (Resolume export)")
        XCTAssertEqual(heightAtomBE, 288, "fixture height should be 288 (Resolume export)")
        print("[HapMEncoderTests] fixture dims (from stsd): \(widthAtomBE)×\(heightAtomBE)")
    }

    // MARK: - 5. Construction at 1080p (smoke)

    /// Cheap sanity test — confirms `prepare(...)` succeeds at the
    /// production resolution before the heavier tests above run.
    func testHapM_Construction_1080p() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapm-ctor-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let encoder = try HapMEncoder(width: 1920, height: 1080, fps: 30, destURL: tmp)
        // One frame so finish() emits a valid moov.
        let frame = try halfAlphaFrame(width: 1920, height: 1080)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
    }

    // MARK: - Inline HapM decoder (single-Snappy form, 0xBF + 0xB1)

    /// Decode a HapMEncoder-emitted single-Snappy outer packet to a
    /// straight-RGBA byte buffer at (width, height). Walks the outer
    /// 0x0D, snappy-decompresses both inner sections, decodes the
    /// HapY BC3 stream via CPURender + scaled-YCoCg inverse, decodes
    /// the HapA BC4 stream via inline unpacking, and composes.
    ///
    /// Does NOT handle chunked-Snappy (0xCF / 0xC1) — the fixture
    /// path skips round-trip for that reason.
    private func decodeHapMOuterSingleSnappy(outerPacket: Data,
                                             width w: Int, height h: Int) throws -> [UInt8] {
        let outer = try parseHAPSectionHeader(packet: outerPacket)
        guard outer.sectionType == 0x0D else {
            throw LocalParseError.malformed(String(format: "outer 0x%02X != 0x0D", outer.sectionType))
        }
        let payload = outerPacket.subdata(
            in: outer.payloadOffset..<(outer.payloadOffset + outer.payloadLength))

        var rgb: [UInt8]? = nil
        var alphaPlane: [UInt8]? = nil

        var cursor = 0
        while cursor < payload.count {
            let region = payload.subdata(in: cursor..<payload.count)
            let inner = try parseHAPSectionHeader(packet: region)
            let payloadSnappy = region.subdata(
                in: inner.payloadOffset..<(inner.payloadOffset + inner.payloadLength))
            switch inner.sectionType {
            case 0xBF:
                let bc3 = try payloadSnappy.uncompressedUsingSnappy()
                let cg = try CPURender.cgImageFromDXT(
                    dxtBytes: bc3, variant: .dxt5,
                    width: w, height: h)
                let intermediateRGBA = rawRGBA(from: cg, expectedCount: w * h * 4)
                rgb = invertHapY(intermediateRGBA, width: w, height: h)
            case 0xB1:
                let bc4 = try payloadSnappy.uncompressedUsingSnappy()
                alphaPlane = unpackBC4Plane(blocks: bc4, width: w, height: h)
            default:
                throw LocalParseError.malformed(
                    String(format: "inner type 0x%02X unsupported by inline decode", inner.sectionType))
            }
            cursor += inner.payloadOffset + inner.payloadLength
        }

        let rgbBuf = rgb ?? [UInt8](repeating: 0xFF, count: w * h * 3)
        let alphaBuf = alphaPlane ?? [UInt8](repeating: 0xFF, count: w * h)

        var out = [UInt8](repeating: 0xFF, count: w * h * 4)
        for i in 0..<(w * h) {
            out[i * 4 + 0] = rgbBuf[i * 3 + 0]
            out[i * 4 + 1] = rgbBuf[i * 3 + 1]
            out[i * 4 + 2] = rgbBuf[i * 3 + 2]
            out[i * 4 + 3] = alphaBuf[i]
        }
        return out
    }

    /// Scaled-YCoCg inverse (Castaño & van Waveren 2007) — converts a
    /// HapY-style BC3-decoded RGBA buffer into straight RGB.
    /// Intermediate RGBA layout: R = Co+offset, G = Cg+offset,
    /// B = scale_byte ∈ {0, 8, 24}, A = Y.
    private func invertHapY(_ intermediate: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            let off = i * 4
            let r_in = Double(intermediate[off + 0]) / 255.0
            let g_in = Double(intermediate[off + 1]) / 255.0
            let b_in = Double(intermediate[off + 2]) / 255.0
            let y    = Double(intermediate[off + 3]) / 255.0
            let s = 1.0 / ((255.0 / 8.0) * b_in + 1.0)
            let co = (r_in - 0.5) * s
            let cg = (g_in - 0.5) * s
            let r = y + co - cg
            let g = y + cg
            let b = y - co - cg
            let oOff = i * 3
            out[oOff + 0] = byteClamp(r * 255.0)
            out[oOff + 1] = byteClamp(g * 255.0)
            out[oOff + 2] = byteClamp(b * 255.0)
        }
        return out
    }

    @inline(__always)
    private func byteClamp(_ v: Double) -> UInt8 {
        if v <= 0 { return 0 }
        if v >= 255 { return 255 }
        return UInt8(v.rounded())
    }

    private func rawRGBA(from cg: CGImage, expectedCount: Int) -> [UInt8] {
        guard let provider = cg.dataProvider,
              let cfData = provider.data,
              CFDataGetLength(cfData) >= expectedCount else {
            return []
        }
        return [UInt8](UnsafeBufferPointer(start: CFDataGetBytePtr(cfData),
                                           count: expectedCount))
    }

    /// Inline BC4 single-channel decoder (mirrors HAPValidationHarnessTests'
    /// `unpackBC4PlaneInline` and Phase B's HapABlockPackerTests pattern).
    private func unpackBC4Plane(blocks: Data, width: Int, height: Int) -> [UInt8] {
        precondition(width % 4 == 0 && height % 4 == 0)
        let wBlocks = width / 4
        let hBlocks = height / 4
        var out = [UInt8](repeating: 0, count: width * height)
        for by in 0..<hBlocks {
            for bx in 0..<wBlocks {
                let blockOff = (by * wBlocks + bx) * 8
                let a0 = blocks[blockOff]
                let a1 = blocks[blockOff + 1]
                var pal = [UInt8](repeating: 0, count: 8)
                pal[0] = a0; pal[1] = a1
                let a0i = Int(a0), a1i = Int(a1)
                if a0 > a1 {
                    for i in 2...7 {
                        let num = a0i * (8 - i) + a1i * (i - 1)
                        pal[i] = UInt8((num + 3) / 7)
                    }
                } else {
                    for i in 2...5 {
                        let num = a0i * (6 - i) + a1i * (i - 1)
                        pal[i] = UInt8((num + 2) / 5)
                    }
                    pal[6] = 0; pal[7] = 255
                }
                var indices: UInt64 = 0
                for k in 0..<6 {
                    indices |= UInt64(blocks[blockOff + 2 + k]) << (k * 8)
                }
                for py in 0..<4 {
                    for px in 0..<4 {
                        let bitOff = (py * 4 + px) * 3
                        let idx = Int((indices >> bitOff) & 0x07)
                        out[(by * 4 + py) * width + (bx * 4 + px)] = pal[idx]
                    }
                }
            }
        }
        return out
    }

    // MARK: - Inline section header parser

    struct LocalSectionHeader {
        let sectionType: UInt8
        let payloadOffset: Int
        let payloadLength: Int
    }
    enum LocalParseError: Error { case malformed(String) }

    private func parseHAPSectionHeader(packet: Data) throws -> LocalSectionHeader {
        guard packet.count >= 4 else { throw LocalParseError.malformed("packet < 4 bytes") }
        let base = packet.startIndex
        let b0 = UInt32(packet[base])
        let b1 = UInt32(packet[base + 1])
        let b2 = UInt32(packet[base + 2])
        let type = packet[base + 3]
        let lengthShort = b0 | (b1 << 8) | (b2 << 16)
        if lengthShort == 0 {
            guard packet.count >= 8 else { throw LocalParseError.malformed("extended header < 8 B") }
            let l0 = UInt32(packet[base + 4])
            let l1 = UInt32(packet[base + 5])
            let l2 = UInt32(packet[base + 6])
            let l3 = UInt32(packet[base + 7])
            let lengthLong = l0 | (l1 << 8) | (l2 << 16) | (l3 << 24)
            return LocalSectionHeader(sectionType: type, payloadOffset: 8,
                                      payloadLength: Int(lengthLong))
        }
        return LocalSectionHeader(sectionType: type, payloadOffset: 4,
                                  payloadLength: Int(lengthShort))
    }

    // MARK: - Atom helpers

    private func findAtom(_ children: [AtomNode], path: [String]) -> AtomNode? {
        var current = children
        var found: AtomNode?
        for type in path {
            guard let node = current.first(where: { $0.type == type }) else { return nil }
            found = node
            current = node.children
        }
        return found
    }

    private func extractFirstSampleBytes(data: Data, tree: AtomTree) throws -> Data {
        guard let stsz = findAtom(tree.children,
                                  path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = findAtom(tree.children,
                                  path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            throw NSError(domain: "HapMTest", code: 1)
        }
        let stszBody = stsz.bodyRange
        // stsz body: 4B v+f, 4B sample_size (0 = per-sample table), 4B count,
        // then per-sample sizes when sample_size == 0.
        let constSize = readBE32(data, at: stszBody.lowerBound + 4)
        let firstSampleSize: Int
        if constSize != 0 {
            firstSampleSize = Int(constSize)
        } else {
            firstSampleSize = Int(readBE32(data, at: stszBody.lowerBound + 12))
        }
        let stcoBody = stco.bodyRange
        let firstSampleOffset = Int(readBE32(data, at: stcoBody.lowerBound + 8))
        return data.subdata(in: firstSampleOffset..<(firstSampleOffset + firstSampleSize))
    }

    private func readBE32(_ data: Data, at index: Int) -> UInt32 {
        let b0 = UInt32(data[index])
        let b1 = UInt32(data[index + 1])
        let b2 = UInt32(data[index + 2])
        let b3 = UInt32(data[index + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

// MARK: - Atom tree (private to this file)

private struct AtomNode {
    let type: String
    let range: Range<Int>
    let bodyRange: Range<Int>
    let children: [AtomNode]
}

private struct AtomTree {
    let data: Data
    let children: [AtomNode]

    init(data: Data, range: Range<Int>) {
        self.data = data
        self.children = AtomTree.parse(data: data, range: range)
    }

    private static func parse(data: Data, range: Range<Int>) -> [AtomNode] {
        var out: [AtomNode] = []
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            let sz32 = Int(readBE32(data, at: p))
            let typeStr = String(bytes: data[(p+4)..<(p+8)], encoding: .isoLatin1) ?? "????"
            let bodyStart: Int
            let atomEnd: Int
            if sz32 == 0 {
                bodyStart = p + 8
                atomEnd = range.upperBound
            } else if sz32 == 1 {
                let large = Int(readBE64(data, at: p + 8))
                bodyStart = p + 16
                atomEnd = p + large
            } else {
                bodyStart = p + 8
                atomEnd = p + sz32
            }
            let kids: [AtomNode]
            if isContainerAtomType(typeStr) {
                kids = AtomTree.parse(data: data, range: bodyStart..<atomEnd)
            } else if typeStr == "stsd" {
                let inner = bodyStart + 8
                kids = AtomTree.parse(data: data, range: inner..<atomEnd)
            } else {
                kids = []
            }
            out.append(AtomNode(type: typeStr,
                                range: p..<atomEnd,
                                bodyRange: bodyStart..<atomEnd,
                                children: kids))
            p = atomEnd
            if sz32 == 0 { break }
        }
        return out
    }

    private static func readBE32(_ data: Data, at index: Int) -> UInt32 {
        let b0 = UInt32(data[index])
        let b1 = UInt32(data[index + 1])
        let b2 = UInt32(data[index + 2])
        let b3 = UInt32(data[index + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func readBE64(_ data: Data, at index: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[index + i]) }
        return v
    }

    private static func isContainerAtomType(_ type: String) -> Bool {
        switch type {
        case "moov", "trak", "mdia", "minf", "stbl", "dinf", "edts", "udta":
            return true
        default:
            return false
        }
    }
}
