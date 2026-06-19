import XCTest
import CoreVideo
import CoreMedia
@testable import GlEncCore

final class DXVFormatTests: XCTestCase {

    func testTierMapping() {
        XCTAssertEqual(DXVFormat.dxt1.tier, .normal)
        XCTAssertEqual(DXVFormat.dxt5.tier, .normal)
        XCTAssertEqual(DXVFormat.ycg6.tier, .hq)
        XCTAssertEqual(DXVFormat.yg10.tier, .hq)
    }

    func testAlpha() {
        XCTAssertFalse(DXVFormat.dxt1.hasAlpha)
        XCTAssertTrue(DXVFormat.dxt5.hasAlpha)
        XCTAssertFalse(DXVFormat.ycg6.hasAlpha)
        XCTAssertTrue(DXVFormat.yg10.hasAlpha)
    }

    /// Verified byte-level against ~/Movies/Testfiles/dxv3-*.mov in the
    /// 2026-05-09 recon. On disk the per-frame Tag is little-endian, so
    /// "DXT1" appears as "1TXD" and so on.
    func testFrameTagBytes() {
        XCTAssertEqual(DXVFormat.dxt1.frameTagBytes, [0x31, 0x54, 0x58, 0x44]) // "1TXD"
        XCTAssertEqual(DXVFormat.dxt5.frameTagBytes, [0x35, 0x54, 0x58, 0x44]) // "5TXD"
        XCTAssertEqual(DXVFormat.ycg6.frameTagBytes, [0x36, 0x47, 0x43, 0x59]) // "6GCY"
        XCTAssertEqual(DXVFormat.yg10.frameTagBytes, [0x30, 0x31, 0x47, 0x59]) // "01GY"
    }

    func testAllCasesCovered() {
        // 4 DXV3 + 5 HAP variants (HapA arrived in v0.9.2; HapM in v0.9.3 Phase C).
        XCTAssertEqual(DXVFormat.allCases.count, 9)
    }
}

// MARK: - Phase 1 — PixelFrame + NoOpEncoder

final class PixelFrameTests: XCTestCase {

    /// Minimal helper: allocate a BGRA CVPixelBuffer with a deterministic
    /// per-pixel pattern so assertions can confirm bytes survive the
    /// PixelFrame.bgraBytes() copy.
    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA,
            nil, &pb)
        precondition(status == kCVReturnSuccess && pb != nil)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        // Fill with a checkerboard-ish pattern: pixel = ((x+y)&0xFF) for each channel.
        for y in 0..<height {
            for x in 0..<width {
                let p = base.advanced(by: y * bpr + x * 4)
                    .bindMemory(to: UInt8.self, capacity: 4)
                let v = UInt8((x + y) & 0xFF)
                p[0] = v       // B
                p[1] = v       // G
                p[2] = v       // R
                p[3] = 0xFF    // A
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    func testInstantiationCarriesDimensions() {
        let buf = makeBuffer(width: 64, height: 32)
        let frame = PixelFrame(pixelBuffer: buf, presentationTime: .zero)
        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.height, 32)
        // codedWidth / codedHeight default to presentation dims when not
        // supplied (Phase 1; Phase 2+ will pass 16-aligned values).
        XCTAssertEqual(frame.codedWidth, 64)
        XCTAssertEqual(frame.codedHeight, 32)
        XCTAssertEqual(frame.presentationTime, .zero)
    }

    func testCodedDimsOverride() {
        let buf = makeBuffer(width: 64, height: 32)
        let frame = PixelFrame(
            pixelBuffer: buf,
            presentationTime: CMTime(value: 1, timescale: 30),
            codedWidth: 80,
            codedHeight: 48
        )
        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.codedWidth, 80)
        XCTAssertEqual(frame.codedHeight, 48)
    }

    func testBGRABytesSizeAndContent() {
        let buf = makeBuffer(width: 8, height: 4)
        let frame = PixelFrame(pixelBuffer: buf, presentationTime: .zero)
        let bytes = frame.bgraBytes()
        XCTAssertEqual(bytes.count, 8 * 4 * 4)  // width * height * 4

        // Pixel (0,0): all-zero BGR + alpha 255.
        XCTAssertEqual(bytes[0], 0)
        XCTAssertEqual(bytes[1], 0)
        XCTAssertEqual(bytes[2], 0)
        XCTAssertEqual(bytes[3], 0xFF)

        // Pixel (3, 2): v = (3+2) & 0xFF = 5.
        let off = (2 * 8 + 3) * 4
        XCTAssertEqual(bytes[off + 0], 5)
        XCTAssertEqual(bytes[off + 1], 5)
        XCTAssertEqual(bytes[off + 2], 5)
        XCTAssertEqual(bytes[off + 3], 0xFF)
    }
}

