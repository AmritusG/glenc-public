// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics

/// CPU-side renderer for code paths without a GPU context (thumbnails, the
/// DXVRenderer software fallback, HAP CPU paths). Turns already-decoded
/// block bytes or HQ planes into RGBA / CGImage.
///
/// DXT1 / DXT5 (BC1 / BC3) go through DXVKit's `dxvk_blocks_to_rgba` (the
/// same BC1 / BC3 convention the hand-written decoder here used; proven
/// identical on every DXV file in ~/Movies apart from the last partial block
/// row, which the old decoder skipped). HQ planes use Resolume Arena's YCoCg
/// convention (chroma midpoint 127.5, nearest chroma, R / B overflow folding),
/// as DXVKit and the GPU renderers do.
public enum CPURender {

    public enum RenderError: Error, CustomStringConvertible {
        case dimensionMismatch(String)
        case cgImageFailed
        public var description: String {
            switch self {
            case .dimensionMismatch(let s): return "CPURender dimension mismatch: \(s)"
            case .cgImageFailed: return "CPURender: CGImage allocation failed"
            }
        }
    }

    // MARK: - DXT

    /// Decode DXT1 or DXT5 block bytes laid out with 16-pixel-aligned block
    /// columns (the DXV layout, `paddedW * height / 2` or `paddedW * height`
    /// bytes) into a display-size CGImage.
    public static func cgImageFromDXT(
        dxtBytes: Data,
        variant: DXVVariant,
        width: Int, height: Int
    ) throws -> CGImage {
        precondition(variant == .dxt1 || variant == .dxt5,
                     "cgImageFromDXT only handles DXT1/DXT5; use cgImageFromHQ for HQ variants")
        let paddedW = (width + 15) / 16 * 16
        let expected = (paddedW / 4) * (height / 4) * (variant == .dxt1 ? 8 : 16)
        guard dxtBytes.count >= expected else {
            throw RenderError.dimensionMismatch(
                "DXT bytes \(dxtBytes.count) < expected \(expected) for \(width)x\(height) (padded to \(paddedW))")
        }
        let rgba = try DXVKitBridge.rgbaFromDXT(dxtBytes, alpha: variant == .dxt5, width: width, height: height)
        return try cgImageFromRGBA(rgba: rgba, width: width, height: height)
    }

    /// DXT1 block bytes → RGBA8 (`width * height * 4`, alpha 255).
    /// `paddingAlignment`: the block-row alignment of `dxt1` — 16 for DXV
    /// (the default), 4 for HAP.
    public static func unpackDXT1ToRGBA(
        dxt1: Data, width: Int, height: Int,
        paddingAlignment: Int = 16
    ) -> [UInt8] {
        unpackDXTToRGBA(dxt1, alpha: false, width: width, height: height, paddingAlignment: paddingAlignment)
    }

    /// DXT5 block bytes → RGBA8 (`width * height * 4`, alpha as stored:
    /// premultiplied for DXV, straight for HAP Hap5).
    public static func unpackDXT5ToRGBA(
        dxt5: Data, width: Int, height: Int,
        paddingAlignment: Int = 16
    ) -> [UInt8] {
        unpackDXTToRGBA(dxt5, alpha: true, width: width, height: height, paddingAlignment: paddingAlignment)
    }

    private static func unpackDXTToRGBA(_ bytes: Data, alpha: Bool, width: Int, height: Int,
                                        paddingAlignment: Int) -> [UInt8] {
        precondition(paddingAlignment > 0, "paddingAlignment must be positive")
        let blockBytes = alpha ? 16 : 8
        let srcBlocksX = (width + paddingAlignment - 1) / paddingAlignment * paddingAlignment / 4
        let expected = srcBlocksX * (height / 4) * blockBytes
        precondition(bytes.count >= expected,
                     "CPURender.unpackDXT\(alpha ? "5" : "1")ToRGBA: dxtBytes \(bytes.count) < expected \(expected) for " +
                     "\(width)x\(height) (alignment=\(paddingAlignment))")
        // DXVKit's layout has 16-pixel-aligned block columns; re-pad other alignments row by row.
        let dstBlocksX = (width + 15) / 16 * 4
        var blocks = bytes
        if srcBlocksX != dstBlocksX {
            let rows = (height + 3) / 4
            let srcRow = srcBlocksX * blockBytes, dstRow = dstBlocksX * blockBytes
            var repadded = Data(count: rows * dstRow)
            repadded.withUnsafeMutableBytes { dst in
                bytes.withUnsafeBytes { src in
                    for r in 0..<rows where (r + 1) * srcRow <= src.count {
                        dst.baseAddress!.advanced(by: r * dstRow)
                            .copyMemory(from: src.baseAddress!.advanced(by: r * srcRow), byteCount: min(srcRow, dstRow))
                    }
                }
            }
            blocks = repadded
        }
        do {
            return try DXVKitBridge.rgbaFromDXT(blocks, alpha: alpha, width: width, height: height)
        } catch {
            preconditionFailure("CPURender: DXVKit could not lay out \(width)x\(height): \(error)")
        }
    }

    // MARK: - HQ planes

    /// HQ planes (Y / Co / Cg / optional A, e.g. from `DXVHQDecoder`) → CGImage,
    /// in Resolume Arena's convention: nearest chroma, co = Co - 127.5,
    /// cg = Cg - 127.5, R = Y - cg + co, G = Y + cg, B = Y - cg - co, R / B
    /// overflow folded into the other channel, rounded at the end. Alpha is
    /// passed through.
    ///
    /// `width` is the plane stride (`y.count / height`); pass `displayWidth`
    /// to crop the padding columns.
    public static func cgImageFromHQ(
        y: [UInt8], co: [UInt8], cg: [UInt8], a: [UInt8]?,
        width: Int, height: Int,
        chromaWidth: Int, chromaHeight: Int,
        displayWidth: Int? = nil
    ) throws -> CGImage {
        guard y.count == width * height else {
            throw RenderError.dimensionMismatch("Y plane \(y.count) != \(width)*\(height)")
        }
        guard co.count == chromaWidth * chromaHeight,
              cg.count == chromaWidth * chromaHeight else {
            throw RenderError.dimensionMismatch("Co/Cg plane size mismatch")
        }
        if let a = a, a.count != width * height {
            throw RenderError.dimensionMismatch("A plane \(a.count) != \(width)*\(height)")
        }
        let outW = displayWidth ?? width
        var rgba = [UInt8](repeating: 0xFF, count: outW * height * 4)
        for row in 0..<height {
            let cRow = min(chromaHeight - 1, row / 2) * chromaWidth
            for col in 0..<outW {
                let cIdx = cRow + min(chromaWidth - 1, col / 2)
                let (r, g, b) = arenaYCoCgToRGB(y: Int(y[row * width + col]), co: Int(co[cIdx]), cg: Int(cg[cIdx]))
                let o = (row * outW + col) * 4
                rgba[o] = r; rgba[o + 1] = g; rgba[o + 2] = b
                rgba[o + 3] = a.map { $0[row * width + col] } ?? 255
            }
        }
        return try cgImageFromRGBA(rgba: rgba, width: outW, height: height)
    }

    /// Arena's YCoCg → RGB on 8-bit samples, in half units (no floating point):
    /// v2 = 2v, chroma centred on 127.5 = 255 half units.
    @inline(__always)
    static func arenaYCoCgToRGB(y: Int, co: Int, cg: Int) -> (UInt8, UInt8, UInt8) {
        let y2 = 2 * y, co2 = 2 * co - 255, cg2 = 2 * cg - 255
        var r = y2 - cg2 + co2
        let g = y2 + cg2
        var b = y2 - cg2 - co2
        if r < 0 { b += r; r = 0 }
        if b < 0 { r += b; b = 0 }
        if r > 510 { b += r - 510; r = 510 }
        if b > 510 { r += b - 510; b = 510 }
        @inline(__always) func out(_ v2: Int) -> UInt8 { UInt8(clamping: max(0, (v2 + 1) >> 1)) }
        return (out(r), out(g), out(b))
    }

    // MARK: - Helpers

    /// RGBA8 (not premultiplied, alpha last) → CGImage.
    static func cgImageFromRGBA(rgba: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { throw RenderError.cgImageFailed }
        // Bytes are NOT premultiplied: labelling them `.last` is what keeps
        // source-over compositing onto transparent regions correct (Crate's
        // checkerboard bake-in, v0.4.17).
        guard let img = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { throw RenderError.cgImageFailed }
        return img
    }
}
