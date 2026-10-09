// SPDX-License-Identifier: MIT
import Foundation
import GlanceCore

/// One decoded HQ frame (YCG6 / YG10), as `DXVPlayer` hands it to a renderer.
///
/// Since the DXVKit wave the frame carries DXVKit's **block streams**, which
/// the renderers upload as compressed textures (the GPU decodes them):
///   - `lumaBlocks`: BC4 Y (YCG6) or BC5 Y + A (YG10), `codedWidth x codedHeight`
///   - `chromaBlocks`: BC5 Co + Cg, `chromaWidth x chromaHeight`
///
/// **Dimension contract:** `width` / `height` are the display size (aspect-fit
/// math); `codedWidth` / `codedHeight` are both padded to 16 (DXVKit's coded
/// texture, which the renderers crop back to the display size by UV);
/// `chromaWidth` / `chromaHeight` = coded / 2.
///
/// The 8-bit planes `y` / `co` / `cg` / `a` are still available for callers
/// that read pixels on the CPU: for block frames they are unpacked on each
/// access (`codedWidth x codedHeight` and `chromaWidth x chromaHeight` bytes).
/// Frames built with the plane initializer carry planes only and have no
/// block streams, so the GPU renderers cannot draw them.
public struct DXVHQFrame: Sendable {
    private enum Storage: Sendable {
        case planes(y: [UInt8], co: [UInt8], cg: [UInt8], a: [UInt8]?)
        case blocks(luma: Data, chroma: Data, hasAlpha: Bool)
    }
    private let storage: Storage

    public let width: Int          // display
    public let height: Int         // display
    public let codedWidth: Int     // padded to 16
    public let codedHeight: Int    // padded to 16
    public let chromaWidth: Int    // = codedWidth / 2
    public let chromaHeight: Int   // = codedHeight / 2

    /// A frame from 8-bit planes (CPU use only; see the type note).
    public init(
        y: [UInt8], co: [UInt8], cg: [UInt8], a: [UInt8]?,
        width: Int, height: Int,
        codedWidth: Int, codedHeight: Int,
        chromaWidth: Int, chromaHeight: Int
    ) {
        storage = .planes(y: y, co: co, cg: cg, a: a)
        self.width = width; self.height = height
        self.codedWidth = codedWidth; self.codedHeight = codedHeight
        self.chromaWidth = chromaWidth; self.chromaHeight = chromaHeight
    }

    /// A frame from DXVKit block streams (what `DXVPlayer` produces).
    public init(lumaBlocks: Data, chromaBlocks: Data, hasAlpha: Bool,
                width: Int, height: Int, codedWidth: Int, codedHeight: Int) {
        storage = .blocks(luma: lumaBlocks, chroma: chromaBlocks, hasAlpha: hasAlpha)
        self.width = width; self.height = height
        self.codedWidth = codedWidth; self.codedHeight = codedHeight
        self.chromaWidth = codedWidth / 2; self.chromaHeight = codedHeight / 2
    }

    /// BC4 Y (YCG6) or BC5 Y + A (YG10) blocks; nil for a plane frame.
    public var lumaBlocks: Data? { if case .blocks(let l, _, _) = storage { return l }; return nil }
    /// BC5 Co + Cg blocks; nil for a plane frame.
    public var chromaBlocks: Data? { if case .blocks(_, let c, _) = storage { return c }; return nil }
    /// True for YG10 (alpha present).
    public var hasAlpha: Bool {
        switch storage {
        case .planes(_, _, _, let a): return a != nil
        case .blocks(_, _, let h): return h
        }
    }

    public var y: [UInt8] {
        switch storage {
        case .planes(let y, _, _, _): return y
        case .blocks(let l, _, let h): return Self.unpack(l, bc5: h, width: codedWidth, height: codedHeight).0
        }
    }
    public var a: [UInt8]? {
        switch storage {
        case .planes(_, _, _, let a): return a
        case .blocks(let l, _, let h): return h ? Self.unpack(l, bc5: true, width: codedWidth, height: codedHeight).1 : nil
        }
    }
    public var co: [UInt8] {
        switch storage {
        case .planes(_, let co, _, _): return co
        case .blocks(_, let c, _): return Self.unpack(c, bc5: true, width: chromaWidth, height: chromaHeight).0
        }
    }
    public var cg: [UInt8] {
        switch storage {
        case .planes(_, _, let cg, _): return cg
        case .blocks(_, let c, _): return Self.unpack(c, bc5: true, width: chromaWidth, height: chromaHeight).1!
        }
    }

    private static func unpack(_ blocks: Data, bc5: Bool, width: Int, height: Int) -> ([UInt8], [UInt8]?) {
        var c0 = [UInt8](repeating: 0, count: width * height)
        var c1: [UInt8]? = bc5 ? [UInt8](repeating: 0, count: width * height) : nil
        let count = (width / 4) * (height / 4)
        blocks.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self).baseAddress!
            c0.withUnsafeMutableBufferPointer { o0 in
                if bc5 {
                    c1!.withUnsafeMutableBufferPointer { o1 in
                        BC4BC5Unpack.unpackBC5Plane(blocks: b, blocksCount: count, outputChannel0: o0.baseAddress!,
                                                    outputChannel1: o1.baseAddress!, width: width, height: height)
                    }
                } else {
                    BC4BC5Unpack.unpackBC4Plane(blocks: b, blocksCount: count, output: o0.baseAddress!,
                                                width: width, height: height)
                }
            }
        }
        return (c0, c1)
    }
}
