// SPDX-License-Identifier: MIT
import Foundation
import CoreVideo
import CoreMedia
import CoreGraphics

/// One frame at the encoder boundary. Phase 1 carries a BGRA8 pixel
/// buffer through to the NoOp encoder; Phase 2+ will use the same shape
/// to feed BGRA pixels into the DXT1/HQ encoders, with `codedWidth` /
/// `codedHeight` carrying the 16-multiple padded dimensions Resolume
/// requires (coded ≥ presentation, padding zero-filled by the caller).
///
/// `alphaInfo` describes how to interpret the alpha byte in `bgraBytes()`
/// output (always at byte offset 3 of each pixel, since the buffer is
/// BGRA-byte-order). DXT1 ignores it; DXT5's encoder normalizes per
/// DECISIONS-2026-05-10-PassB.md (un-premultiply when premultiplied,
/// straight-through when straight, force α=255 when none).
public struct PixelFrame {
    public let pixelBuffer: CVPixelBuffer
    public let width: Int           // presentation
    public let height: Int          // presentation
    public let codedWidth: Int      // ≥ width, multiple of 16 from Phase 2+
    public let codedHeight: Int     // ≥ height, multiple of 16 from Phase 2+
    public let presentationTime: CMTime
    public let alphaInfo: CGImageAlphaInfo

    public init(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        codedWidth: Int? = nil,
        codedHeight: Int? = nil,
        alphaInfo: CGImageAlphaInfo = .last
    ) {
        self.pixelBuffer = pixelBuffer
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        self.width = w
        self.height = h
        self.codedWidth = codedWidth ?? w
        self.codedHeight = codedHeight ?? h
        self.presentationTime = presentationTime
        self.alphaInfo = alphaInfo
    }

    /// Tightly-packed BGRA bytes (no row stride padding). NoOpEncoder
    /// returns this verbatim. Phase 2's DXT1Encoder consumes the same
    /// representation as input to its 4×4 block walker.
    public func bgraBytes() -> Data {
        let w = self.width
        let h = self.height
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return Data() }

        let outBytesPerRow = w * 4
        var out = Data(count: w * h * 4)
        out.withUnsafeMutableBytes { destPtr in
            let dest = destPtr.baseAddress!
            for row in 0..<h {
                let src = base.advanced(by: row * bytesPerRow)
                memcpy(
                    dest.advanced(by: row * outBytesPerRow),
                    src,
                    outBytesPerRow
                )
            }
        }
        return out
    }
}
