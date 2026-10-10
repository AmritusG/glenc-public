// SPDX-License-Identifier: MIT
//
// DXV3 frame encoder over DXVKit (AmritusG/dxvkit, clean-room MIT, pinned
// exact 1.0.0). Replaces GlEnc's own DXT1 / DXT5 / YCG6 / YG10 packet
// writers (the LGPL ports of FFmpeg's dxvenc.c / dxv.c are gone).
//
// One DXVKit `DXVEncoder` per output file, one packet per frame. GlEnc
// keeps its own container writer (VariantMOVWriter: audio, rational
// timescale, udta) and its source-alpha normalisation:
//
//   DXT1 / YCG6  no alpha: α forced to 255.
//   DXT5, YG10   STRAIGHT colour (DECISIONS-2026-05-10-PassB for DXT5;
//                DECISIONS-2026-10-10 for YG10, Amrit: "Straight"): a
//                premultiplied source is un-premultiplied, a straight one
//                passes (AlphaNormalization, shared with Hap5 / HapA / HapM).
//                Up to v1.5.0 YG10 wrote premultiplied colour (PassD, AME's
//                convention); `premultipliedInput` is never set now.
//
// YCG6 / YG10 colour is DXVKit's exact, unrounded YCoCg (chroma midpoint
// 127.5: the Arena / Alley convention, Amrit: "Keep exact.").

import Foundation
import CoreGraphics
import DXVKit

public final class DXVKitFrameEncoder: FrameEncoder {

    public enum EncoderError: Error, CustomStringConvertible {
        case notDXV3(DXVFormat)
        case notPrepared
        case unexpectedFrameDimensions(expectedW: Int, expectedH: Int, gotW: Int, gotH: Int)
        case bgraSizeMismatch(expected: Int, got: Int)
        case unsupportedAlphaInfo(CGImageAlphaInfo)

        public var description: String {
            switch self {
            case .notDXV3(let f): return "DXVKitFrameEncoder: \(f.label) is not a DXV3 variant"
            case .notPrepared: return "DXVKitFrameEncoder: encode() called before prepare()"
            case .unexpectedFrameDimensions(let ew, let eh, let gw, let gh):
                return "DXVKitFrameEncoder: prepared for \(ew)×\(eh) but got frame \(gw)×\(gh)"
            case .bgraSizeMismatch(let e, let g): return "DXVKitFrameEncoder: BGRA size \(g) ≠ expected \(e)"
            case .unsupportedAlphaInfo(let info):
                return "DXVKitFrameEncoder: alphaOnly source frames are not supported (got \(info.rawValue))"
            }
        }
    }

    /// Every DXV encode uses DXVKit's BEST effort: measured on the W3
    /// testsrc2 source and 150 frames of a real 4444 clip it beats both
    /// FAST (+0.17 – 0.55 dB) and GlEnc's own BC1 / BC3 blocks re-packed by
    /// DXVKit (+0.29 dB at the same size), at 5 – 16 ms per 1080p frame
    /// (docs/dxvkit-swap/arms-2026-10-09-M3.txt).
    static let effort: DXVEffort = .best

    public let format: DXVFormat
    private let variant: DXVKit.DXVVariant
    private var encoder: DXVEncoder?
    private var rgba: [UInt8] = []
    private var width = 0, height = 0

    public init(format: DXVFormat) throws {
        switch format {
        case .dxt1: variant = .dxt1
        case .dxt5: variant = .dxt5
        case .ycg6: variant = .ycg6
        case .yg10: variant = .yg10
        default: throw EncoderError.notDXV3(format)
        }
        self.format = format
    }

    public func prepare(width: Int, height: Int, fps: Double, hasAlpha: Bool) throws {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        rgba = [UInt8](repeating: 0, count: width * height * 4)
        encoder = try DXVEncoder(
            variant: variant, width: width, height: height,
            options: DXVEncodeOptions(effort: Self.effort, parallel: true))
    }

    public func encode(frame: PixelFrame) throws -> Data {
        guard let encoder else { throw EncoderError.notPrepared }
        try fillRGBA(from: frame)
        return try rgba.withUnsafeBytes { try encoder.encode(rgba: $0.baseAddress!, bytesPerRow: width * 4) }
    }

    public func finish() throws {}

    /// Block plane `index` of the last encoded packet, as DXVKit packed it
    /// (verification: a DXVKit decode of the packet must return exactly
    /// these bytes). Nil before the first frame or for a missing plane.
    public func withPackedPlane<R>(_ index: Int, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R? {
        try encoder?.withPackedPlane(index, body)
    }

    /// BGRA frame → the RGBA this variant encodes (see the file header).
    private func fillRGBA(from frame: PixelFrame) throws {
        guard frame.width == width && frame.height == height else {
            throw EncoderError.unexpectedFrameDimensions(expectedW: width, expectedH: height,
                                                         gotW: frame.width, gotH: frame.height)
        }
        let bgra = frame.bgraBytes()
        guard bgra.count == width * height * 4 else {
            throw EncoderError.bgraSizeMismatch(expected: width * height * 4, got: bgra.count)
        }
        let mode: AlphaNormalization
        do { mode = try AlphaNormalization.mode(for: frame.alphaInfo) } catch AlphaNormalization.Error.unsupportedAlphaInfo(let i) {
            throw EncoderError.unsupportedAlphaInfo(i)
        }
        let n = width * height
        bgra.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: UInt8.self)
            rgba.withUnsafeMutableBufferPointer { d in
                switch format {
                case .dxt1, .ycg6:
                    for i in 0..<n {
                        d[i * 4] = s[i * 4 + 2]; d[i * 4 + 1] = s[i * 4 + 1]; d[i * 4 + 2] = s[i * 4]; d[i * 4 + 3] = 255
                    }
                default:   // .dxt5, .yg10: straight
                    for i in 0..<n {
                        let (r, g, b, a) = mode.apply(r: s[i * 4 + 2], g: s[i * 4 + 1], b: s[i * 4], a: s[i * 4 + 3])
                        d[i * 4] = r; d[i * 4 + 1] = g; d[i * 4 + 2] = b; d[i * 4 + 3] = a
                    }
                }
            }
        }
    }
}
