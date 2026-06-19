// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation
import CoreGraphics

/// CPU-side renderer used by code paths that have no GL context — most
/// notably the Quick Look extension [Phase 6b]. Decodes a DXV variant's
/// already-decompressed bytes into a CGImage.
///
/// For DXT1/DXT5: software BC1/BC3 block decompression (S3TC reference
/// implementation) followed by RGBA pack and CGImage construction.
///
/// For YCG6/YG10: takes the existing DXVHQDecoder output (Y/Co/Cg/A
/// planes) and runs the non-reversible YCoCg → RGB inverse on CPU
/// (matching the GL shader from Phase 4d.4) plus chroma upsample
/// (nearest-neighbour for simplicity; matches "good enough for a
/// thumbnail" — bilinear would be a few extra lines if needed later).
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

    // MARK: - Public API

    /// Decode DXT1 or DXT5 frame bytes (already LZF-decompressed by
    /// the caller's `DXVPacketDecoder.decompressDXTn`) into RGBA and
    /// return a CGImage.
    ///
    /// Resolume's DXV3 encoder pads BC1/BC3 block data to a 16-pixel-aligned
    /// width (228 blocks per row for a 908-pixel-wide source vs the 227 the
    /// display width would suggest). This function decodes at the padded
    /// width into a padded RGBA buffer, then crops the resulting CGImage to
    /// the display width. The caller is responsible for delivering enough
    /// `dxtBytes` for the padded layout — i.e. pass `paddedW * height / 2`
    /// (DXT1) or `paddedW * height` (DXT5) as `expectedSize` to
    /// `DXVPacketDecoder.decompressDXTn`. No-op for widths already %16==0
    /// (1920, 1280, 720, etc.).
    public static func cgImageFromDXT(
        dxtBytes: Data,
        variant: DXVVariant,
        width: Int, height: Int
    ) throws -> CGImage {
        precondition(variant == .dxt1 || variant == .dxt5,
                     "cgImageFromDXT only handles DXT1/DXT5; use cgImageFromHQ for HQ variants")

        let paddedW = (width + 15) / 16 * 16
        let blocksW = paddedW / 4
        let blocksH = height / 4
        let expected = blocksW * blocksH * (variant == .dxt1 ? 8 : 16)
        guard dxtBytes.count >= expected else {
            throw RenderError.dimensionMismatch(
                "DXT bytes \(dxtBytes.count) < expected \(expected) for \(width)x\(height) (padded to \(paddedW))")
        }

        var rgba = [UInt8](repeating: 0xFF, count: paddedW * height * 4)
        rgba.withUnsafeMutableBufferPointer { outBuf in
            let outPtr = outBuf.baseAddress!
            dxtBytes.withUnsafeBytes { rawBuf in
                let blockPtr = rawBuf.bindMemory(to: UInt8.self).baseAddress!
                if variant == .dxt1 {
                    BC1.decompress(
                        blocks: blockPtr, output: outPtr,
                        width: paddedW, height: height)
                } else {
                    BC3.decompress(
                        blocks: blockPtr, output: outPtr,
                        width: paddedW, height: height)
                }
            }
        }
        let paddedImage = try cgImageFromRGBA(rgba: rgba, width: paddedW, height: height)
        if paddedW == width { return paddedImage }
        guard let cropped = paddedImage.cropping(
            to: CGRect(x: 0, y: 0, width: width, height: height)
        ) else { throw RenderError.cgImageFailed }
        return cropped
    }

    /// Decode an HQ frame (Y/Co/Cg/optional A planes from DXVHQDecoder)
    /// into RGBA + CGImage. Uses the non-reversible YCoCg inverse from
    /// Phase 4d.4. Chroma is upsampled with nearest-neighbour 2× scaling.
    ///
    /// `width` is the **source plane stride** (must equal `y.count / height`,
    /// `co.count / chromaHeight * chromaWidth`, etc.); for files whose display
    /// width isn't 16-pixel-aligned, callers can pass the padded coded width
    /// here and provide `displayWidth` to crop the final CGImage. When
    /// `displayWidth` is nil (the default), no crop happens — preserving the
    /// pre-existing API contract for 16-aligned callers.
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

        var rgba = [UInt8](repeating: 0xFF, count: width * height * 4)
        let chromaXScale = Double(width) / Double(chromaWidth)
        let chromaYScale = Double(height) / Double(chromaHeight)

        for row in 0..<height {
            let chromaRow = min(chromaHeight - 1, Int(Double(row) / chromaYScale))
            let chromaRowBase = chromaRow * chromaWidth
            let rowBase = row * width
            let outRowBase = rowBase * 4
            for col in 0..<width {
                let chromaCol = min(chromaWidth - 1, Int(Double(col) / chromaXScale))
                let yI = Int(y[rowBase + col])
                let coI = Int(co[chromaRowBase + chromaCol]) - 128
                let cgI = Int(cg[chromaRowBase + chromaCol]) - 128

                // Non-reversible YCoCg → RGB (Phase 4d.4).
                //   t = y - cg
                //   R = t + co
                //   G = y + cg
                //   B = t - co
                let t = yI - cgI
                let r = clamp(t + coI)
                let g = clamp(yI + cgI)
                let b = clamp(t - coI)

                let outBase = outRowBase + col * 4
                rgba[outBase]     = UInt8(r)
                rgba[outBase + 1] = UInt8(g)
                rgba[outBase + 2] = UInt8(b)
                rgba[outBase + 3] = a.map { $0[rowBase + col] } ?? 255
            }
        }
        let sourceImage = try cgImageFromRGBA(rgba: rgba, width: width, height: height)
        let target = displayWidth ?? width
        if target == width { return sourceImage }
        guard let cropped = sourceImage.cropping(
            to: CGRect(x: 0, y: 0, width: target, height: height)
        ) else { throw RenderError.cgImageFailed }
        return cropped
    }

    /// Decode DXT1 or DXT5 frame bytes into a flat RGBA byte array
    /// (no CGImage wrapping). Same padding-aware contract as
    /// `cgImageFromDXT`: caller passes `dxtBytes` sized for the padded
    /// 16-pixel-aligned width, function decodes at padded width into
    /// a padded RGBA buffer, then crops to display dimensions before
    /// return.
    ///
    /// Output layout: `width * height * 4` bytes, row-major, RGBA
    /// (alpha as written by BC1/BC3 — premultiplied for DXT5, opaque
    /// 0xFF for DXT1).
    ///
    /// Use this instead of `DXVValidator.unpackDXT*ToRGBA` for any
    /// new caller — it's the canonical, padding-aware path.
    /// `paddingAlignment` selects the encoder's row-alignment
    /// convention. DXV3 (Resolume's encoder) pads BC1/BC3 block
    /// rows to 16-pixel-aligned widths → pass 16 (the default,
    /// preserving prior behaviour). HAP encoders pad only to
    /// 4-pixel block alignment → pass 4.
    public static func unpackDXT1ToRGBA(
        dxt1: Data, width: Int, height: Int,
        paddingAlignment: Int = 16
    ) -> [UInt8] {
        return unpackDXTToRGBA(dxtBytes: dxt1, variant: .dxt1,
                               width: width, height: height,
                               paddingAlignment: paddingAlignment)
    }

    public static func unpackDXT5ToRGBA(
        dxt5: Data, width: Int, height: Int,
        paddingAlignment: Int = 16
    ) -> [UInt8] {
        return unpackDXTToRGBA(dxtBytes: dxt5, variant: .dxt5,
                               width: width, height: height,
                               paddingAlignment: paddingAlignment)
    }

    private static func unpackDXTToRGBA(
        dxtBytes: Data, variant: DXVVariant,
        width: Int, height: Int,
        paddingAlignment: Int = 16
    ) -> [UInt8] {
        precondition(paddingAlignment > 0, "paddingAlignment must be positive")
        let pad = paddingAlignment
        let paddedW = (width + pad - 1) / pad * pad
        let blocksW = paddedW / 4
        let blocksH = height / 4
        let expected = blocksW * blocksH * (variant == .dxt1 ? 8 : 16)
        precondition(dxtBytes.count >= expected,
                     "CPURender.unpackDXT\(variant == .dxt1 ? "1" : "5")ToRGBA: " +
                     "dxtBytes \(dxtBytes.count) < expected \(expected) for " +
                     "\(width)x\(height) (padded to \(paddedW), alignment=\(pad))")

        var padded = [UInt8](repeating: 0xFF, count: paddedW * height * 4)
        padded.withUnsafeMutableBufferPointer { outBuf in
            let outPtr = outBuf.baseAddress!
            dxtBytes.withUnsafeBytes { rawBuf in
                let blockPtr = rawBuf.bindMemory(to: UInt8.self).baseAddress!
                if variant == .dxt1 {
                    BC1.decompress(blocks: blockPtr, output: outPtr,
                                   width: paddedW, height: height)
                } else {
                    BC3.decompress(blocks: blockPtr, output: outPtr,
                                   width: paddedW, height: height)
                }
            }
        }
        if paddedW == width { return padded }

        // Crop padded rows down to display width.
        let dstStride = width * 4
        let srcStride = paddedW * 4
        var cropped = [UInt8](repeating: 0, count: width * height * 4)
        cropped.withUnsafeMutableBufferPointer { dst in
            padded.withUnsafeBufferPointer { src in
                for row in 0..<height {
                    let dstBase = row * dstStride
                    let srcBase = row * srcStride
                    memcpy(dst.baseAddress!.advanced(by: dstBase),
                           src.baseAddress!.advanced(by: srcBase),
                           dstStride)
                }
            }
        }
        return cropped
    }

    // MARK: - Helpers

    @inline(__always)
    private static func clamp(_ v: Int) -> Int {
        v < 0 ? 0 : (v > 255 ? 255 : v)
    }

    private static func cgImageFromRGBA(rgba: [UInt8], width: Int, height: Int) throws -> CGImage {
        let bytesPerRow = width * 4
        let provider = CGDataProvider(data: Data(rgba) as CFData)
        guard let provider = provider else { throw RenderError.cgImageFailed }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = [
            // Bytes are NOT premultiplied — RGB stays at raw values, alpha
            // is the 4th channel as-is. Labeling as `.last` matches what
            // CPURender actually writes. Previously labeled `.premultipliedLast`,
            // which caused source-over compositing onto transparent regions
            // to pick up CPURender's 0xFF rgba init as if pre-multiplied (i.e.
            // produce white). Discovered while baking checkerboard backgrounds
            // into Crate's thumbnail cache for alpha clips — alpha pixels
            // composited over the checker came out white instead of letting
            // the checker show through.
            CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        ]
        guard let img = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { throw RenderError.cgImageFailed }
        return img
    }
}

// MARK: - BC1 (DXT1) software decompression

/// BC1 / DXT1: 8 bytes/block, 4×4 RGB pixels. Two 16-bit color
/// endpoints (RGB565) followed by 16 2-bit indices (32 bits, LSB-first).
/// Endpoint comparison determines whether we use 4-color mode (with
/// two interpolated colors) or 3-color mode (with one interpolated +
/// transparent black).
private enum BC1 {
    @inline(__always)
    static func decompressBlock(
        block: UnsafePointer<UInt8>,
        output: UnsafeMutablePointer<UInt8>,
        outputStride: Int  // bytes per output row (= width * 4)
    ) {
        let c0 = UInt16(block[0]) | (UInt16(block[1]) << 8)
        let c1 = UInt16(block[2]) | (UInt16(block[3]) << 8)

        var palette: [(UInt8, UInt8, UInt8, UInt8)] = [
            unpack565(c0),
            unpack565(c1),
            (0,0,0,255),
            (0,0,0,255),
        ]
        if c0 > c1 {
            // 4-color mode: two interpolated colors at 1/3 and 2/3.
            palette[2] = lerp(palette[0], palette[1], 1, 3)
            palette[3] = lerp(palette[0], palette[1], 2, 3)
        } else {
            // 3-color mode: one interpolated + transparent.
            palette[2] = lerp(palette[0], palette[1], 1, 2)
            palette[3] = (0, 0, 0, 0)  // transparent
        }

        let bits = UInt32(block[4])
            | (UInt32(block[5]) << 8)
            | (UInt32(block[6]) << 16)
            | (UInt32(block[7]) << 24)

        for row in 0..<4 {
            let rowOffset = row * outputStride
            for col in 0..<4 {
                let pix = row * 4 + col
                let idx = Int((bits >> (pix * 2)) & 0x3)
                let c = palette[idx]
                let outBase = rowOffset + col * 4
                output[outBase]     = c.0
                output[outBase + 1] = c.1
                output[outBase + 2] = c.2
                output[outBase + 3] = c.3
            }
        }
    }

    static func decompress(
        blocks: UnsafePointer<UInt8>,
        output: UnsafeMutablePointer<UInt8>,
        width: Int, height: Int
    ) {
        let blocksW = width / 4
        let blocksH = height / 4
        let outputStride = width * 4
        for blockRow in 0..<blocksH {
            for blockCol in 0..<blocksW {
                let blockIdx = blockRow * blocksW + blockCol
                let blockPtr = blocks.advanced(by: blockIdx * 8)
                let outBase = blockRow * 4 * outputStride + blockCol * 4 * 4
                let outPtr = output.advanced(by: outBase)
                decompressBlock(block: blockPtr, output: outPtr, outputStride: outputStride)
            }
        }
    }
}

// MARK: - BC3 (DXT5) software decompression

/// BC3 / DXT5: 16 bytes/block. First 8 bytes = BC4-style alpha block
/// (two endpoints + 16 3-bit indices). Last 8 bytes = BC1-style color
/// block (always in 4-color mode, even when c0 ≤ c1). The alpha plane
/// here is stored in the alpha-out byte of each pixel; the RGB
/// triplets come from the BC1 portion.
private enum BC3 {
    @inline(__always)
    static func decompressBlock(
        block: UnsafePointer<UInt8>,
        output: UnsafeMutablePointer<UInt8>,
        outputStride: Int
    ) {
        // --- Alpha block (first 8 bytes) ---
        let a0 = UInt32(block[0])
        let a1 = UInt32(block[1])
        var alphaPalette: [UInt8] = Array(repeating: 0, count: 8)
        alphaPalette[0] = UInt8(a0)
        alphaPalette[1] = UInt8(a1)
        if a0 > a1 {
            for i in 1...6 {
                let ui = UInt32(i)
                let v = ((7 - ui) * a0 + ui * a1) / 7
                alphaPalette[1 + i] = UInt8(v)
            }
        } else {
            for i in 1...4 {
                let ui = UInt32(i)
                let v = ((5 - ui) * a0 + ui * a1) / 5
                alphaPalette[1 + i] = UInt8(v)
            }
            alphaPalette[6] = 0
            alphaPalette[7] = 255
        }
        var aBits: UInt64 = 0
        for i in 0..<6 {
            aBits |= UInt64(block[2 + i]) << (i * 8)
        }

        // --- Color block (next 8 bytes) ---
        let c0 = UInt16(block[8])  | (UInt16(block[9])  << 8)
        let c1 = UInt16(block[10]) | (UInt16(block[11]) << 8)
        var palette: [(UInt8, UInt8, UInt8)] = [
            unpack565RGB(c0),
            unpack565RGB(c1),
            (0,0,0),
            (0,0,0),
        ]
        // BC3 always uses 4-color interpretation (no 3-color punchthrough).
        palette[2] = lerpRGB(palette[0], palette[1], 1, 3)
        palette[3] = lerpRGB(palette[0], palette[1], 2, 3)

        let cBits = UInt32(block[12])
            | (UInt32(block[13]) << 8)
            | (UInt32(block[14]) << 16)
            | (UInt32(block[15]) << 24)

        for row in 0..<4 {
            let rowOffset = row * outputStride
            for col in 0..<4 {
                let pix = row * 4 + col
                let cIdx = Int((cBits >> (pix * 2)) & 0x3)
                let aIdx = Int((aBits >> (pix * 3)) & 0x7)
                let rgb = palette[cIdx]
                let alpha = alphaPalette[aIdx]
                let outBase = rowOffset + col * 4
                output[outBase]     = rgb.0
                output[outBase + 1] = rgb.1
                output[outBase + 2] = rgb.2
                output[outBase + 3] = alpha
            }
        }
    }

    static func decompress(
        blocks: UnsafePointer<UInt8>,
        output: UnsafeMutablePointer<UInt8>,
        width: Int, height: Int
    ) {
        let blocksW = width / 4
        let blocksH = height / 4
        let outputStride = width * 4
        for blockRow in 0..<blocksH {
            for blockCol in 0..<blocksW {
                let blockIdx = blockRow * blocksW + blockCol
                let blockPtr = blocks.advanced(by: blockIdx * 16)
                let outBase = blockRow * 4 * outputStride + blockCol * 4 * 4
                let outPtr = output.advanced(by: outBase)
                decompressBlock(block: blockPtr, output: outPtr, outputStride: outputStride)
            }
        }
    }
}

// MARK: - 565 → 888 unpack helpers

@inline(__always)
private func unpack565(_ rgb565: UInt16) -> (UInt8, UInt8, UInt8, UInt8) {
    let rgb = unpack565RGB(rgb565)
    return (rgb.0, rgb.1, rgb.2, 255)
}

@inline(__always)
private func unpack565RGB(_ rgb565: UInt16) -> (UInt8, UInt8, UInt8) {
    // 5 bits R, 6 bits G, 5 bits B, scaled to 8-bit by replicating MSBs
    // into the LSBs (standard S3TC convention; matches FFmpeg).
    let r5 = UInt32((rgb565 >> 11) & 0x1F)
    let g6 = UInt32((rgb565 >> 5)  & 0x3F)
    let b5 = UInt32(rgb565 & 0x1F)
    let r = (r5 << 3) | (r5 >> 2)
    let g = (g6 << 2) | (g6 >> 4)
    let b = (b5 << 3) | (b5 >> 2)
    return (UInt8(r), UInt8(g), UInt8(b))
}

@inline(__always)
private func lerp(_ a: (UInt8, UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8, UInt8),
                  _ num: Int, _ denom: Int) -> (UInt8, UInt8, UInt8, UInt8) {
    let r = ((denom - num) * Int(a.0) + num * Int(b.0)) / denom
    let g = ((denom - num) * Int(a.1) + num * Int(b.1)) / denom
    let bl = ((denom - num) * Int(a.2) + num * Int(b.2)) / denom
    return (UInt8(r), UInt8(g), UInt8(bl), 255)
}

@inline(__always)
private func lerpRGB(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8),
                     _ num: Int, _ denom: Int) -> (UInt8, UInt8, UInt8) {
    let r = ((denom - num) * Int(a.0) + num * Int(b.0)) / denom
    let g = ((denom - num) * Int(a.1) + num * Int(b.1)) / denom
    let bl = ((denom - num) * Int(a.2) + num * Int(b.2)) / denom
    return (UInt8(r), UInt8(g), UInt8(bl))
}
