// SPDX-License-Identifier: MIT
import Foundation

/// Plane-level API for the HQ variants (YCG6 / YG10), kept for callers that
/// decode payloads themselves (Crate's thumbnail and measurement code).
/// Since the DXVKit wave the decode is DXVKit's (see `DXVKitBridge`): the
/// packet is decoded to BC4 / BC5 block streams and unpacked here into the
/// 8-bit planes these results always carried.
///
/// Same contract as before: `payload` is the bytes after the 12-byte header
/// (`DXVPacketDecoder.parseHeader`), `codedWidth` the width padded to 16,
/// `codedHeight` the display height. Planes are `codedWidth x codedHeight`
/// (Y, A) and `codedWidth/2 x codedHeight/2` (Co, Cg). One difference: the
/// last rows of a plane whose height is not a multiple of 4, which the old
/// decoder left at 0, now hold the decoded picture.
///
/// For display, prefer `DXVPlayer` (GPU block streams) or `DXVThumbnail`
/// (DXVKit RGBA, Resolume Arena's colour convention).
public enum DXVHQDecoder {

    public enum Variant {
        case ycg6
        case yg10
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case decodeFailed(String)

        public var description: String {
            switch self { case .decodeFailed(let s): return "DXV HQ: \(s)" }
        }
    }

    /// YG10: all four planes.
    public struct YG10Result {
        /// Y (luma) plane: width * height bytes.
        public let y: [UInt8]
        /// A (alpha) plane: width * height bytes.
        public let a: [UInt8]
        /// Co plane: chromaWidth * chromaHeight.
        public let co: [UInt8]
        /// Cg plane: chromaWidth * chromaHeight.
        public let cg: [UInt8]
        public let width: Int
        public let height: Int
        public let chromaWidth: Int
        public let chromaHeight: Int
        /// Packet decode time (ms); since DXVKit both planes decode in one call.
        public let cocgYAMs: Double
        /// Time to unpack Y + A (ms).
        public let bc5YAMs: Double
        /// 0: Co + Cg decode in the same DXVKit call as Y + A (`cocgYAMs`).
        public let cocgCoCgMs: Double
        /// Time to unpack Co + Cg (ms).
        public let bc5CoCgMs: Double
        public init(y: [UInt8], a: [UInt8], co: [UInt8], cg: [UInt8], width: Int, height: Int, chromaWidth: Int, chromaHeight: Int, cocgYAMs: Double, bc5YAMs: Double, cocgCoCgMs: Double, bc5CoCgMs: Double) {
            self.y = y; self.a = a; self.co = co; self.cg = cg
            self.width = width; self.height = height
            self.chromaWidth = chromaWidth; self.chromaHeight = chromaHeight
            self.cocgYAMs = cocgYAMs; self.bc5YAMs = bc5YAMs
            self.cocgCoCgMs = cocgCoCgMs; self.bc5CoCgMs = bc5CoCgMs
        }
    }

    /// YCG6 luma: the Y plane.
    public struct LumaResult {
        /// 8-bit luma plane: width * height bytes, row-major.
        public let luma: [UInt8]
        public let width: Int
        public let height: Int
        /// Packet decode time (ms).
        public let cgoMs: Double
        /// Time to unpack the Y plane (ms).
        public let bc4Ms: Double
        /// Pass this to `decompressYCG6ChromaPlane(startCursor:)` as before.
        /// (DXVKit decodes the whole packet, so the value is no longer a byte
        /// position; it is the payload length.)
        public let postCursor: Int
        public init(luma: [UInt8], width: Int, height: Int, cgoMs: Double, bc4Ms: Double, postCursor: Int) {
            self.luma = luma; self.width = width; self.height = height
            self.cgoMs = cgoMs; self.bc4Ms = bc4Ms; self.postCursor = postCursor
        }
    }

    /// YCG6 chroma: the Co + Cg planes (width/2 x height/2 each).
    public struct ChromaResult {
        public let co: [UInt8]
        public let cg: [UInt8]
        public let chromaWidth: Int
        public let chromaHeight: Int
        /// Packet decode time (ms).
        public let cocgMs: Double
        /// Time to unpack Co + Cg (ms).
        public let bc5Ms: Double
        /// The payload length (see `LumaResult.postCursor`).
        public let postCursor: Int
        public init(co: [UInt8], cg: [UInt8], chromaWidth: Int, chromaHeight: Int, cocgMs: Double, bc5Ms: Double, postCursor: Int) {
            self.co = co; self.cg = cg
            self.chromaWidth = chromaWidth; self.chromaHeight = chromaHeight
            self.cocgMs = cocgMs; self.bc5Ms = bc5Ms; self.postCursor = postCursor
        }
    }

    /// YCG6: decode the payload and return the Y plane.
    public static func decompressYCG6LumaPlane(
        payload: Data, codedWidth: Int, codedHeight: Int
    ) throws -> LumaResult {
        let t0 = Date()
        let frame = try decode(payload, tag: "YCG6", codedWidth: codedWidth, codedHeight: codedHeight)
        let t1 = Date()
        let y = DXVKitBridge.unpack(frame, plane: 0, width: codedWidth, height: codedHeight).ch0
        return LumaResult(luma: y, width: codedWidth, height: codedHeight,
                          cgoMs: t1.timeIntervalSince(t0) * 1000, bc4Ms: Date().timeIntervalSince(t1) * 1000,
                          postCursor: payload.count)
    }

    /// YCG6: decode the payload and return the Co + Cg planes. `startCursor`
    /// is accepted for compatibility and ignored (DXVKit decodes the whole
    /// packet).
    public static func decompressYCG6ChromaPlane(
        payload: Data, startCursor: Int,
        codedWidth: Int, codedHeight: Int
    ) throws -> ChromaResult {
        let t0 = Date()
        let frame = try decode(payload, tag: "YCG6", codedWidth: codedWidth, codedHeight: codedHeight)
        let t1 = Date()
        let cw = codedWidth / 2, ch = codedHeight / 2
        let c = DXVKitBridge.unpack(frame, plane: 1, width: cw, height: ch)
        return ChromaResult(co: c.ch0, cg: c.ch1!, chromaWidth: cw, chromaHeight: ch,
                            cocgMs: t1.timeIntervalSince(t0) * 1000, bc5Ms: Date().timeIntervalSince(t1) * 1000,
                            postCursor: payload.count)
    }

    /// YG10: decode the payload and return Y, A, Co, Cg.
    public static func decompressYG10(
        payload: Data, codedWidth: Int, codedHeight: Int
    ) throws -> YG10Result {
        let t0 = Date()
        let frame = try decode(payload, tag: "YG10", codedWidth: codedWidth, codedHeight: codedHeight)
        let t1 = Date()
        let ya = DXVKitBridge.unpack(frame, plane: 0, width: codedWidth, height: codedHeight)
        let t2 = Date()
        let cw = codedWidth / 2, ch = codedHeight / 2
        let c = DXVKitBridge.unpack(frame, plane: 1, width: cw, height: ch)
        return YG10Result(y: ya.ch0, a: ya.ch1!, co: c.ch0, cg: c.ch1!,
                          width: codedWidth, height: codedHeight, chromaWidth: cw, chromaHeight: ch,
                          cocgYAMs: t1.timeIntervalSince(t0) * 1000, bc5YAMs: t2.timeIntervalSince(t1) * 1000,
                          cocgCoCgMs: 0, bc5CoCgMs: Date().timeIntervalSince(t2) * 1000)
    }

    private static func decode(_ payload: Data, tag: String, codedWidth: Int, codedHeight: Int) throws -> DXVKitFrame {
        do { return try DXVKitBridge.hqFrame(payload: payload, tag: tag, codedWidth: codedWidth, codedHeight: codedHeight) }
        catch { throw DecodeError.decodeFailed("\(error)") }
    }
}
