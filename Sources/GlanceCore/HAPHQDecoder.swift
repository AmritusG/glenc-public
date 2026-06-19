// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation
import CoreGraphics

/// HAP "high-quality" variants — HapY (Scaled YCoCg DXT5), HapM
/// (HapY + alpha multi-section), HapA (RGTC1 alpha-only). The DXV3
/// HQ codecs share the same colorspace but pack their planes
/// differently (separate BC4/BC5 planes); a unified DXVHQDecoder
/// can't be reused as-is. This file mirrors the role
/// `DXVHQDecoder` plays for YCG6/YG10 but is HAP-aware.
///
/// Phase 6.b lands HapY here; HapM/HapA fill in alongside their
/// HITME validation gates.
public enum HAPHQDecoder {

    public enum HQError: Error, CustomStringConvertible {
        case dimensionMismatch(String)
        case cgImageFailed
        public var description: String {
            switch self {
            case .dimensionMismatch(let s): return "HAPHQDecoder dimension mismatch: \(s)"
            case .cgImageFailed:            return "HAPHQDecoder: CGImage allocation failed"
            }
        }
    }

    /// HapY (Scaled YCoCg DXT5) — single DXT5 texture whose channels
    /// the encoder reinterprets:
    ///   `R = Co + offset`  (5-bit BC1-encoded)
    ///   `G = Cg + offset`  (6-bit BC1-encoded)
    ///   `B = scale-encoding` (constant per-block, encodes 1/2/4)
    ///   `A = Y`            (8-bit BC4-encoded, full resolution)
    /// where `offset = 128/255` and `scale` is a per-block divisor
    /// applied to Co/Cg to gain precision on low-dynamic-range
    /// blocks (Castaño & van Waveren, *Real-Time YCoCg-DXT
    /// Compression*, 2007).
    ///
    /// Inverse per pixel (`display_fp` from the same paper):
    ///   `s  = 1 / ((255/8) * B + 1)`
    ///   `Co = (R - 0.5) * s`
    ///   `Cg = (G - 0.5) * s`
    ///   `R' = Y + Co - Cg`
    ///   `G' = Y + Cg`
    ///   `B' = Y - Co - Cg`
    /// Plain (non-reversible) YCoCg.
    public static func decodeHapY(
        dxt5Bytes: Data,
        width: Int,
        height: Int
    ) throws -> CGImage {
        let rgba = try decodeHapYToRGBA(
            dxt5Bytes: dxt5Bytes, width: width, height: height
        )
        return try cgImageFromRGBA(rgba: rgba, width: width, height: height)
    }

    /// Phase 6.b post-tag (v0.6.1): raw-RGBA variant for the
    /// playback hot path. Skips the CGImage allocation that
    /// thumbnail callers need — playback engines (Crate's
    /// HAPPreviewLayer) just upload these bytes straight to GL.
    /// RGBA layout: 4 bytes/pixel, A=0xFF (HapY has no alpha).
    public static func decodeHapYToRGBA(
        dxt5Bytes: Data,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        let rgb = try unpackHapYToRGB(
            dxt5Bytes: dxt5Bytes, width: width, height: height
        )
        var rgba = [UInt8](repeating: 0xFF, count: width * height * 4)
        rgb.withUnsafeBufferPointer { src in
            rgba.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(width * height) {
                    dst[i * 4    ] = src[i * 3    ]
                    dst[i * 4 + 1] = src[i * 3 + 1]
                    dst[i * 4 + 2] = src[i * 3 + 2]
                    dst[i * 4 + 3] = 0xFF
                }
            }
        }
        return rgba
    }

    /// HapA — RGTC1 / BC4 single-channel alpha. Decompresses the
    /// payload via `BC4BC5Unpack.unpackBC4Plane`, then renders as
    /// white-RGB-with-variable-alpha so the result reads as an
    /// alpha shape when composited over a checkerboard (Crate's
    /// `ThumbnailExtractor` does this composite at the cache layer).
    ///
    /// `unsupportedVariant` was the placeholder until now; this is
    /// the spec-implemented decode. No standalone HapA file was
    /// available for visual gate during 6.b; the HapA path is
    /// exercised indirectly via `decodeHapM`, which composites a
    /// HapY RGB plane with this BC4 alpha plane. Real-world HapA
    /// files surface the standalone path; per Standing Rule #6,
    /// edges will fix forward from real consumers.
    public static func decodeHapA(
        rgtc1Bytes: Data,
        width: Int,
        height: Int
    ) throws -> CGImage {
        let rgba = try decodeHapAToRGBA(
            rgtc1Bytes: rgtc1Bytes, width: width, height: height
        )
        return try cgImageFromRGBA(rgba: rgba, width: width, height: height)
    }

    /// Raw-RGBA variant of decodeHapA for the playback hot path.
    /// White RGB + variable alpha from the BC4 plane.
    public static func decodeHapAToRGBA(
        rgtc1Bytes: Data,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        let alpha = try unpackHapAToAlpha(
            rgtc1Bytes: rgtc1Bytes, width: width, height: height
        )
        var rgba = [UInt8](repeating: 0xFF, count: width * height * 4)
        alpha.withUnsafeBufferPointer { src in
            rgba.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(width * height) {
                    dst[i * 4    ] = 0xFF
                    dst[i * 4 + 1] = 0xFF
                    dst[i * 4 + 2] = 0xFF
                    dst[i * 4 + 3] = src[i]
                }
            }
        }
        return rgba
    }

    /// HapM — outer section type `0x0D` wrapping two top-level
    /// sections: a HapY (`0xAF` / `0xBF`) carrying scaled YCoCg
    /// color, and a HapA (`0xA1` / `0xB1`) carrying RGTC1 alpha.
    /// Section order isn't fixed by the spec; we scan both, route
    /// by kind, and composite RGB-from-HapY + alpha-from-HapA into
    /// a single RGBA image.
    ///
    /// A HapM frame containing only a HapY section (no alpha) is
    /// valid per spec — output is opaque RGB. A HapM frame with
    /// only HapA produces white-RGB + alpha (same as standalone
    /// HapA). Missing both: error.
    public static func decodeHapM(
        outerPacket: Data,
        width: Int,
        height: Int
    ) throws -> CGImage {
        let rgba = try decodeHapMToRGBA(
            outerPacket: outerPacket, width: width, height: height
        )
        return try cgImageFromRGBA(rgba: rgba, width: width, height: height)
    }

    /// Raw-RGBA variant of decodeHapM for the playback hot path.
    /// Parses the outer 0x0D, decodes inner HapY + HapA sections,
    /// composites into RGBA with straight (non-premultiplied)
    /// alpha. Returns 4 bytes/pixel.
    public static func decodeHapMToRGBA(
        outerPacket: Data,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        // Strip the outer 0x0D header to get the inner-sections
        // buffer. `HAPPacketDecoder.parseSectionHeader` returns the
        // payload region; we then walk inner sections inside it.
        let outerHeader = try HAPPacketDecoder.parseSectionHeader(packet: outerPacket)
        guard outerHeader.sectionType == 0x0D else {
            throw HQError.dimensionMismatch(
                String(format: "HapM expected outer 0x0D, got 0x%02X", outerHeader.sectionType)
            )
        }
        let innerStart = outerPacket.startIndex + outerHeader.payloadOffset
        let innerEnd = innerStart + outerHeader.payloadLength
        let innerBuffer = outerPacket.subdata(in: innerStart..<innerEnd)

        var hapYPayload: Data?
        var hapAPayload: Data?

        var cursor = 0
        while cursor < innerBuffer.count {
            // Slice the remaining buffer; parseSectionHeader reads
            // from the start.
            let subpacket = innerBuffer.subdata(
                in: innerBuffer.startIndex + cursor ..< innerBuffer.endIndex
            )
            let header = try HAPPacketDecoder.parseSectionHeader(packet: subpacket)
            let innerTotal = header.payloadOffset + header.payloadLength
            let innerPacket = subpacket.subdata(in: subpacket.startIndex ..< subpacket.startIndex + innerTotal)
            let (payload, kind) = try HAPPacketDecoder.decode(packet: innerPacket)
            switch kind {
            case .scaledYCoCg:
                hapYPayload = payload
            case .rgtc1Alpha:
                hapAPayload = payload
            case .dxt1Rgb, .dxt5Rgba:
                // Spec allows other combinations in 0x0D but for
                // HapM the canonical pair is HapY + HapA. Reject
                // unexpected inner types — surface to the caller
                // for diagnosis rather than silently produce
                // wrong-looking output.
                throw HQError.dimensionMismatch(
                    "Unexpected inner section type \(kind) in HapM"
                )
            }
            cursor += innerTotal
        }

        guard hapYPayload != nil || hapAPayload != nil else {
            throw HQError.dimensionMismatch("HapM outer contained no recognised inner sections")
        }

        // Compose RGBA. RGB comes from HapY (or opaque white if
        // missing); alpha comes from HapA (or 0xFF if missing).
        let rgb: [UInt8]
        if let hapYPayload {
            rgb = try unpackHapYToRGB(dxt5Bytes: hapYPayload, width: width, height: height)
        } else {
            rgb = [UInt8](repeating: 0xFF, count: width * height * 3)
        }
        let alpha: [UInt8]
        if let hapAPayload {
            alpha = try unpackHapAToAlpha(rgtc1Bytes: hapAPayload, width: width, height: height)
        } else {
            alpha = [UInt8](repeating: 0xFF, count: width * height)
        }

        var rgba = [UInt8](repeating: 0xFF, count: width * height * 4)
        rgb.withUnsafeBufferPointer { rgbBuf in
            alpha.withUnsafeBufferPointer { aBuf in
                rgba.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<(width * height) {
                        dst[i * 4    ] = rgbBuf[i * 3    ]
                        dst[i * 4 + 1] = rgbBuf[i * 3 + 1]
                        dst[i * 4 + 2] = rgbBuf[i * 3 + 2]
                        dst[i * 4 + 3] = aBuf[i]
                    }
                }
            }
        }
        return rgba
    }

    // MARK: - Internal byte-level helpers

    /// HapY decode body shared by `decodeHapY` (which wraps in
    /// opaque RGBA) and `decodeHapM` (which composes the RGB with
    /// the HapA alpha plane). Returns `width * height * 3` raw
    /// RGB bytes.
    private static func unpackHapYToRGB(
        dxt5Bytes: Data,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        // HAP encoders pad rows only to 4-pixel block boundaries
        // (DXT block size), NOT to 16 like Resolume's DXV3 encoder.
        // Passing paddingAlignment=4 sizes the expected byte count
        // to match HAP's encoder output for non-16-aligned widths
        // (e.g. 2200, 908). Same family as Glance v0.4.15.
        let rgba = CPURender.unpackDXT5ToRGBA(
            dxt5: dxt5Bytes, width: width, height: height,
            paddingAlignment: 4
        )
        guard rgba.count == width * height * 4 else {
            throw HQError.dimensionMismatch(
                "DXT5 unpack returned \(rgba.count) bytes; expected \(width * height * 4)"
            )
        }
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let pixelCount = width * height
        rgba.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                let src = inBuf.baseAddress!
                let dst = outBuf.baseAddress!
                for i in 0..<pixelCount {
                    let off = i * 4
                    let r_in = Double(src[off    ]) / 255.0
                    let g_in = Double(src[off + 1]) / 255.0
                    let b_in = Double(src[off + 2]) / 255.0
                    let y    = Double(src[off + 3]) / 255.0

                    let s  = 1.0 / ((255.0 / 8.0) * b_in + 1.0)
                    let co = (r_in - 0.5) * s
                    let cg = (g_in - 0.5) * s

                    let r = y + co - cg
                    let g = y + cg
                    let b = y - co - cg

                    let dstOff = i * 3
                    dst[dstOff    ] = byte(r)
                    dst[dstOff + 1] = byte(g)
                    dst[dstOff + 2] = byte(b)
                }
            }
        }
        return out
    }

    /// HapA decode body shared by `decodeHapA` (white-RGB +
    /// alpha) and `decodeHapM` (HapY-RGB + this alpha). Returns
    /// `width * height` raw alpha bytes via `BC4BC5Unpack.unpackBC4Plane`.
    private static func unpackHapAToAlpha(
        rgtc1Bytes: Data,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        // RGTC1 / BC4: 8 bytes per 4×4 block, single channel.
        // BC4BC5Unpack.unpackBC4Plane requires width & height
        // multiples of 4. Real HAP files satisfy this (encoders
        // pad source dims).
        guard width % 4 == 0, height % 4 == 0 else {
            throw HQError.dimensionMismatch(
                "BC4 requires width/height multiples of 4 (got \(width)x\(height))"
            )
        }
        let blocksPerRow = width / 4
        let blocksPerCol = height / 4
        let expected = blocksPerRow * blocksPerCol * 8
        guard rgtc1Bytes.count >= expected else {
            throw HQError.dimensionMismatch(
                "RGTC1 bytes \(rgtc1Bytes.count) < expected \(expected) for \(width)x\(height)"
            )
        }
        var plane = [UInt8](repeating: 0, count: width * height)
        rgtc1Bytes.withUnsafeBytes { rawBuf in
            let blockPtr = rawBuf.bindMemory(to: UInt8.self).baseAddress!
            plane.withUnsafeMutableBufferPointer { outBuf in
                BC4BC5Unpack.unpackBC4Plane(
                    blocks: blockPtr,
                    blocksCount: blocksPerRow * blocksPerCol,
                    output: outBuf.baseAddress!,
                    width: width, height: height
                )
            }
        }
        return plane
    }

    // MARK: - Helpers

    @inline(__always)
    private static func byte(_ v: Double) -> UInt8 {
        let scaled = v * 255.0
        if scaled <= 0 { return 0 }
        if scaled >= 255 { return 255 }
        return UInt8(scaled.rounded())
    }

    /// CGImage construction from an RGBA byte buffer. Duplicated
    /// from `CPURender.cgImageFromRGBA` (which is private to that
    /// type); not worth a public-API change to share. Same
    /// behaviour: device-RGB color space, `.last` alpha (non-
    /// premultiplied — HapY output is opaque anyway, future HapM
    /// composite needs straight-alpha labelling for source-over
    /// compositing).
    private static func cgImageFromRGBA(
        rgba: [UInt8], width: Int, height: Int
    ) throws -> CGImage {
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            throw HQError.cgImageFailed
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { throw HQError.cgImageFailed }
        return cgImage
    }
}
