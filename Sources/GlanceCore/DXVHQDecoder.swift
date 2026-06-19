// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation

/// HQ DXV variant decoder (YCG6 / YG10) skeleton. Phase 4d builds this
/// out incrementally:
///
///   - 4d.1a: opcode buffer extraction (this file). Validates the
///     opcode decompressor against real packet data; cgo state machine
///     is a stub that just consumes bytes per op_size budget so the
///     prelude can run end-to-end without producing real tex_data.
///   - 4d.1b: dxv_decompress_cgo 17-opcode switch. Real tex_data
///     output. Validate via BC4 unpack against raw YUV ground truth.
///   - 4d.1c: dxv_decompress_cocg + BC5 unpack. Full YCG6 byte-exact
///     against ground truth.
///   - 4d.1d: YG10 (extra cocg call for Y+alpha pair).
///
/// FFmpeg reference: libavcodec/dxv.c, functions dxv_decompress_yo,
/// dxv_decompress_cocg, dxv_decompress_cgo, dxv_decompress_ycg6,
/// dxv_decompress_yg10.
public enum DXVHQDecoder {

    public enum Variant {
        case ycg6
        case yg10
    }

    public enum DecodeError: Error, CustomStringConvertible {
        case truncatedInput(needed: Int, available: Int, where: String)
        case invalidOpOffset(Int)
        case opSizeExceedsMax(opSize: Int, max: Int)
        case unsupportedVariant(String)

        public var description: String {
            switch self {
            case .truncatedInput(let n, let a, let w):
                return "DXV HQ: truncated input at \(w) (needed \(n), have \(a))"
            case .invalidOpOffset(let v):
                return "DXV HQ: invalid op_offset \(v)"
            case .opSizeExceedsMax(let s, let m):
                return "DXV HQ: op_size \(s) exceeds max \(m)"
            case .unsupportedVariant(let v):
                return "DXV HQ: unsupported variant \(v)"
            }
        }
    }

    /// Result of running the prelude+opcode-extraction phase against a
    /// real packet. Used by Phase 4d.1a's validation gate.
    public struct PreludeResult {
        public let variant: Variant
        public let texSize: Int        // expected bytes of luma BC4/BC5 buffer
        public let ctexSize: Int       // expected bytes of chroma BC5 buffer
        public let opSizes: [Int]      // [0] = luma ops, [1..2] = chroma ops, [3] = alpha (yg10)
        public let extractedOpcodes: [Data]  // decompressed opcode buffers, one per opSize
        public let opcodesBytesConsumed: [Int]  // bytes consumed from input per extraction
        public init(variant: Variant, texSize: Int, ctexSize: Int, opSizes: [Int], extractedOpcodes: [Data], opcodesBytesConsumed: [Int]) {
            self.variant = variant
            self.texSize = texSize
            self.ctexSize = ctexSize
            self.opSizes = opSizes
            self.extractedOpcodes = extractedOpcodes
            self.opcodesBytesConsumed = opcodesBytesConsumed
        }
    }

    /// Compute tex_size and ctex_size for a coded width/height pair.
    /// FFmpeg formulas from dxv_decode (lines 982-999).
    public static func computeBufferSizes(
        codedWidth: Int, codedHeight: Int, variant: Variant
    ) -> (texSize: Int, ctexSize: Int, opSizes: [Int]) {
        // For YCG6: tex_ratio=8, raw_ratio=4, ctex_ratio=16, ctex_raw=4.
        // For YG10: tex_ratio=16, raw_ratio=4, ctex_ratio=16, ctex_raw=4.
        // FFmpeg formula:
        //   tex_size  = coded_w / raw_ratio * (coded_h / 4) * tex_ratio
        //   ctex_size = (coded_w/2) / ctex_raw * (coded_h/2 / 4) * ctex_ratio
        let texRatio: Int
        switch variant {
        case .ycg6: texRatio = 8
        case .yg10: texRatio = 16
        }
        let texSize = (codedWidth / 4) * (codedHeight / 4) * texRatio
        let ctexSize = (codedWidth / 8) * (codedHeight / 8) * 16
        // op_size budgets per FFmpeg lines 1001-1004:
        //   op_size[0] = coded_w * coded_h / 16
        //   op_size[1] = coded_w * coded_h / 32
        //   op_size[2] = coded_w * coded_h / 32
        //   op_size[3] = coded_w * coded_h / 16
        //
        // Resolume Alley's encoder writes op_size = area/16 + 1 for some
        // YCG6 outputs (observed deterministically at 908x2276 portrait
        // clips: op_size=129,733 vs the strict area/16=129,732). FFmpeg's
        // libavcodec/dxv.c rejects these files with AVERROR_INVALIDDATA via
        // the same `>` check; we deliberately deviate from FFmpeg's strict
        // semantics by adding a 1-byte margin to accept Alley's slightly-
        // out-of-spec output. The actual op buffer is sized exactly to the
        // file's claimed op_size at allocation time, so the +1 here only
        // relaxes the safety check. Discovered while integrating GlanceCore
        // into Crate's thumbnail pipeline.
        let area = codedWidth * codedHeight
        let opSizes: [Int] = [
            area / 16 + 1,
            area / 32 + 1,
            area / 32 + 1,
            area / 16 + 1,
        ]
        return (texSize, ctexSize, opSizes)
    }

    /// Phase 4d.1a harness: extract opcode buffers from a packet
    /// payload using the prelude + opcode-decompressor. Does NOT yet
    /// produce final tex_data — that's 4d.1b. Validates that the
    /// opcode decompressor produces correctly-sized buffers and
    /// doesn't throw on real input.
    ///
    /// `payload` is the bytes AFTER the 12-byte packet header (i.e.,
    /// what DXVPacketDecoder.parseHeader returns as `payload`).
    public static func extractOpcodes(
        payload: Data, variant: Variant,
        codedWidth: Int, codedHeight: Int
    ) throws -> PreludeResult {
        let (texSize, ctexSize, opSizes) = computeBufferSizes(
            codedWidth: codedWidth, codedHeight: codedHeight, variant: variant)

        var cursor = 0
        var extractedOpcodes: [Data] = []
        var bytesConsumed: [Int] = []

        // Each variant runs through a different sequence of yo/cocg
        // calls. Each call has its own prelude (op_offset + op_size
        // header(s)) followed by the opcode buffer compressed via
        // dxv_decompress_opcodes.
        switch variant {
        case .ycg6:
            // ycg6 = yo (luma) + cocg (chroma).
            try runYoPrelude(
                payload: payload, cursor: &cursor,
                texSize: texSize, maxOpSize: opSizes[0],
                extractedOpcodes: &extractedOpcodes,
                bytesConsumed: &bytesConsumed)
            try runCocgPrelude(
                payload: payload, cursor: &cursor,
                texSize: ctexSize,
                maxOpSize0: opSizes[1], maxOpSize1: opSizes[2],
                extractedOpcodes: &extractedOpcodes,
                bytesConsumed: &bytesConsumed)
        case .yg10:
            // yg10 = cocg (Y+A) + cocg (Co+Cg).
            try runCocgPrelude(
                payload: payload, cursor: &cursor,
                texSize: texSize,
                maxOpSize0: opSizes[0], maxOpSize1: opSizes[3],
                extractedOpcodes: &extractedOpcodes,
                bytesConsumed: &bytesConsumed)
            try runCocgPrelude(
                payload: payload, cursor: &cursor,
                texSize: ctexSize,
                maxOpSize0: opSizes[1], maxOpSize1: opSizes[2],
                extractedOpcodes: &extractedOpcodes,
                bytesConsumed: &bytesConsumed)
        }

        return PreludeResult(
            variant: variant,
            texSize: texSize, ctexSize: ctexSize,
            opSizes: opSizes,
            extractedOpcodes: extractedOpcodes,
            opcodesBytesConsumed: bytesConsumed)
    }

    /// Result of decompressYG10: all four planes (Y, A, Co, Cg) plus
    /// timing breakdown.
    public struct YG10Result {
        /// Y (luma) plane: width * height bytes.
        public let y: [UInt8]
        /// A (alpha) plane: width * height bytes.
        public let a: [UInt8]
        /// Co (chrominance orange) plane: chromaWidth * chromaHeight.
        public let co: [UInt8]
        /// Cg (chrominance green) plane: chromaWidth * chromaHeight.
        public let cg: [UInt8]
        public let width: Int
        public let height: Int
        public let chromaWidth: Int
        public let chromaHeight: Int
        /// Time to run first cocg state machine (Y + A).
        public let cocgYAMs: Double
        /// Time to BC5-unpack Y + A planes.
        public let bc5YAMs: Double
        /// Time to run second cocg state machine (Co + Cg).
        public let cocgCoCgMs: Double
        /// Time to BC5-unpack Co + Cg planes.
        public let bc5CoCgMs: Double
        public init(y: [UInt8], a: [UInt8], co: [UInt8], cg: [UInt8], width: Int, height: Int, chromaWidth: Int, chromaHeight: Int, cocgYAMs: Double, bc5YAMs: Double, cocgCoCgMs: Double, bc5CoCgMs: Double) {
            self.y = y; self.a = a; self.co = co; self.cg = cg
            self.width = width; self.height = height
            self.chromaWidth = chromaWidth; self.chromaHeight = chromaHeight
            self.cocgYAMs = cocgYAMs; self.bc5YAMs = bc5YAMs
            self.cocgCoCgMs = cocgCoCgMs; self.bc5CoCgMs = bc5CoCgMs
        }
    }

    // MARK: - Phase 4d.1b: full luma plane decode for YCG6

    /// Result of decompressYCG6LumaPlane: the unpacked Y plane bytes
    /// (1920×1080 = 2,073,600 bytes), plus diagnostic timing.
    public struct LumaResult {
        /// Raw 8-bit luma plane: width * height bytes, row-major.
        public let luma: [UInt8]
        /// Width/height (echoed for caller convenience).
        public let width: Int
        public let height: Int
        /// Time to decompress the cgo state machine (ms).
        public let cgoMs: Double
        /// Time to BC4-unpack the luma plane (ms).
        public let bc4Ms: Double
        /// New payload cursor position after this sub-decoder.
        public let postCursor: Int
        public init(luma: [UInt8], width: Int, height: Int, cgoMs: Double, bc4Ms: Double, postCursor: Int) {
            self.luma = luma; self.width = width; self.height = height
            self.cgoMs = cgoMs; self.bc4Ms = bc4Ms; self.postCursor = postCursor
        }
    }

    /// Result of decompressYCG6ChromaPlane: Co + Cg planes (each at
    /// 1/4 resolution: width/2 × height/2 bytes), plus timing.
    public struct ChromaResult {
        /// Co (chrominance orange) plane.
        public let co: [UInt8]
        /// Cg (chrominance green) plane.
        public let cg: [UInt8]
        /// Chroma plane dimensions (typically width/2, height/2).
        public let chromaWidth: Int
        public let chromaHeight: Int
        /// Time to run cocg state machine.
        public let cocgMs: Double
        /// Time to BC5-unpack into Co + Cg planes.
        public let bc5Ms: Double
        /// New payload cursor position after this sub-decoder.
        public let postCursor: Int
        public init(co: [UInt8], cg: [UInt8], chromaWidth: Int, chromaHeight: Int, cocgMs: Double, bc5Ms: Double, postCursor: Int) {
            self.co = co; self.cg = cg
            self.chromaWidth = chromaWidth; self.chromaHeight = chromaHeight
            self.cocgMs = cocgMs; self.bc5Ms = bc5Ms; self.postCursor = postCursor
        }
    }

    /// Phase 4d.1b: decode the YCG6 luma plane end-to-end.
    /// Steps: yo prelude → opcode buffer extraction → cgo state machine
    /// to produce BC4 blocks → BC4 unpack to raw luma bytes.
    ///
    /// `payload` is the post-header packet payload.
    /// Returns the decoded luma plane (`width * height` bytes) plus
    /// diagnostic info.
    public static func decompressYCG6LumaPlane(
        payload: Data, codedWidth: Int, codedHeight: Int
    ) throws -> LumaResult {
        let (texSize, _, opSizes) = computeBufferSizes(
            codedWidth: codedWidth, codedHeight: codedHeight, variant: .ycg6)

        // Materialize payload to [UInt8] with 4 bytes of padding
        // (mirroring AV_INPUT_BUFFER_PADDING_SIZE) so the bitstream
        // walker in opcode decompression can read 4 bytes at the
        // logical end without OOB.
        var payloadBytes = Array(payload)
        payloadBytes.append(contentsOf: [0, 0, 0, 0])

        // Read yo header: op_offset, op_size.
        var cursor = 0
        guard cursor + 8 <= payloadBytes.count else {
            throw DecodeError.truncatedInput(
                needed: 8, available: payloadBytes.count - cursor, where: "ycg6-luma yo header")
        }
        let opOffset = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let opSizeHdr = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let dataStart = cursor

        if opOffset < 8 || opOffset - 8 > payloadBytes.count - cursor {
            throw DecodeError.invalidOpOffset(opOffset)
        }
        if opSizeHdr > opSizes[0] {
            throw DecodeError.opSizeExceedsMax(opSize: opSizeHdr, max: opSizes[0])
        }

        // Extract the opcode buffer (the [UInt8] form, since cgo
        // operates on [UInt8]).
        let opcodeStart = cursor + (opOffset - 8)
        let opcodeResult = try DXVHQOpcodeDecoder.decompressOpcodesArray(
            input: payloadBytes, offset: opcodeStart, opSize: opSizeHdr)
        let opData = Array(opcodeResult.opcodes)

        // Allocate texData buffer (BC4 blocks).
        var texData = [UInt8](repeating: 0, count: texSize)

        // Run the cgo state machine, starting from dataStart.
        let cgoStart = Date()
        try texData.withUnsafeMutableBufferPointer { texPtr in
            _ = try DXVHQCgoDecoder.runYoStateMachine(
                payload: payloadBytes,
                dataStart: dataStart,
                texData: texPtr.baseAddress!,
                texSize: texSize,
                opData: opData,
                opSize: opSizeHdr)
        }
        let cgoMs = Date().timeIntervalSince(cgoStart) * 1000

        // BC4-unpack the luma plane.
        let bc4Start = Date()
        var luma = [UInt8](repeating: 0, count: codedWidth * codedHeight)
        texData.withUnsafeBufferPointer { texPtr in
            luma.withUnsafeMutableBufferPointer { lumaPtr in
                BC4BC5Unpack.unpackBC4Plane(
                    blocks: texPtr.baseAddress!,
                    blocksCount: texSize / 8,
                    output: lumaPtr.baseAddress!,
                    width: codedWidth, height: codedHeight)
            }
        }
        let bc4Ms = Date().timeIntervalSince(bc4Start) * 1000

        // Caller-visible postCursor: where the next sub-decoder (cocg)
        // would start. FFmpeg seeks to data_start + op_offset + skip - 8.
        // skip = opcodeResult.bytesConsumed.
        let postCursor = dataStart + opOffset + opcodeResult.bytesConsumed - 8

        return LumaResult(
            luma: luma,
            width: codedWidth, height: codedHeight,
            cgoMs: cgoMs, bc4Ms: bc4Ms,
            postCursor: postCursor)
    }

    // MARK: - Phase 4d.1c: full chroma plane decode for YCG6

    /// Phase 4d.1c: decode the YCG6 chroma planes end-to-end.
    /// Steps: cocg prelude → two opcode buffer extractions → cocg state
    /// machine to produce BC5 blocks → BC5 unpack to raw Co + Cg bytes.
    ///
    /// `payload` is the post-header packet payload.
    /// `startCursor` is where to begin reading (typically the
    /// `postCursor` value returned from `decompressYCG6LumaPlane`).
    /// Returns the decoded Co + Cg planes plus diagnostic info.
    public static func decompressYCG6ChromaPlane(
        payload: Data, startCursor: Int,
        codedWidth: Int, codedHeight: Int
    ) throws -> ChromaResult {
        let (_, ctexSize, opSizes) = computeBufferSizes(
            codedWidth: codedWidth, codedHeight: codedHeight, variant: .ycg6)

        // For YCG6, opSizes layout from extractOpcodes: [op_size_yo,
        // op_size_cocg0, op_size_cocg1, op_size_yo_alpha (unused)].
        // The cocg call uses op_size[1] and op_size[2].
        let maxOpSize0 = opSizes[1]
        let maxOpSize1 = opSizes[2]

        // Materialize payload to [UInt8] with 4 bytes of padding.
        var payloadBytes = Array(payload)
        payloadBytes.append(contentsOf: [0, 0, 0, 0])

        // Read cocg header: op_offset, op_size0, op_size1 (12 bytes).
        var cursor = startCursor
        guard cursor + 12 <= payloadBytes.count else {
            throw DecodeError.truncatedInput(
                needed: 12, available: payloadBytes.count - cursor, where: "ycg6-chroma cocg header")
        }
        let opOffset = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let opSizeHdr0 = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let opSizeHdr1 = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let dataStart = cursor

        if opOffset < 12 || opOffset - 12 > payloadBytes.count - cursor {
            throw DecodeError.invalidOpOffset(opOffset)
        }
        if opSizeHdr0 > maxOpSize0 {
            throw DecodeError.opSizeExceedsMax(opSize: opSizeHdr0, max: maxOpSize0)
        }
        if opSizeHdr1 > maxOpSize1 {
            throw DecodeError.opSizeExceedsMax(opSize: opSizeHdr1, max: maxOpSize1)
        }

        // Skip data section to opcode block, decompress both opcode
        // buffers (channel 0 then channel 1), tracking total bytes
        // consumed. FFmpeg seeks back to data_start afterward.
        var opcodeCursor = cursor + (opOffset - 12)
        let opcodeResult0 = try DXVHQOpcodeDecoder.decompressOpcodesArray(
            input: payloadBytes, offset: opcodeCursor, opSize: opSizeHdr0)
        opcodeCursor += opcodeResult0.bytesConsumed
        let opData0 = Array(opcodeResult0.opcodes)

        let opcodeResult1 = try DXVHQOpcodeDecoder.decompressOpcodesArray(
            input: payloadBytes, offset: opcodeCursor, opSize: opSizeHdr1)
        let opData1 = Array(opcodeResult1.opcodes)

        // Allocate ctexData buffer (BC5 blocks: 16 bytes per 4x4 tile).
        var ctexData = [UInt8](repeating: 0, count: ctexSize)

        // Run the cocg state machine.
        let cocgStart = Date()
        try ctexData.withUnsafeMutableBufferPointer { ctexPtr in
            _ = try DXVHQCgoDecoder.runCocgStateMachine(
                payload: payloadBytes,
                dataStart: dataStart,
                texData: ctexPtr.baseAddress!,
                texSize: ctexSize,
                opData0: opData0, opSize0: opSizeHdr0,
                opData1: opData1, opSize1: opSizeHdr1)
        }
        let cocgMs = Date().timeIntervalSince(cocgStart) * 1000

        // BC5-unpack: each 16-byte block produces two 4x4 channel
        // tiles. Channel 0 (bytes [0..7]) = Co, channel 1 (bytes
        // [8..15]) = Cg. Confirmed by visual rendering test in 4d.2.
        //
        // Note on byte-exact validation: FFmpeg writes BC5 channel 0
        // into its YUV file's "U plane" position and channel 1 into
        // the "V plane" position. The yuv420p convention is U=Cb-ish
        // and V=Cr-ish, but with colorspace=YCOCG, FFmpeg does NOT
        // remap so as to put Co into U and Cg into V; the planes
        // simply hold whatever channel ordering BC5 emitted. So our
        // .co (= BC5 channel 0) byte-matches FFmpeg's U-labeled
        // region even though FFmpeg's "U" actually holds Co
        // semantically here. Visual rendering would fail with
        // FFmpeg's U=Co assumption; we confirmed empirically the
        // semantic ordering is channel0=Co, channel1=Cg.
        let chromaW = codedWidth / 2
        let chromaH = codedHeight / 2
        let bc5Start = Date()
        var co = [UInt8](repeating: 0, count: chromaW * chromaH)
        var cg = [UInt8](repeating: 0, count: chromaW * chromaH)
        ctexData.withUnsafeBufferPointer { ctexPtr in
            co.withUnsafeMutableBufferPointer { coPtr in
                cg.withUnsafeMutableBufferPointer { cgPtr in
                    BC4BC5Unpack.unpackBC5Plane(
                        blocks: ctexPtr.baseAddress!,
                        blocksCount: ctexSize / 16,
                        outputChannel0: coPtr.baseAddress!,   // first half = Co
                        outputChannel1: cgPtr.baseAddress!,   // second half = Cg
                        width: chromaW, height: chromaH)
                }
            }
        }
        let bc5Ms = Date().timeIntervalSince(bc5Start) * 1000

        let postCursor = dataStart + opOffset
                       + opcodeResult0.bytesConsumed
                       + opcodeResult1.bytesConsumed
                       - 12

        return ChromaResult(
            co: co, cg: cg,
            chromaWidth: chromaW, chromaHeight: chromaH,
            cocgMs: cocgMs, bc5Ms: bc5Ms,
            postCursor: postCursor)
    }

    // MARK: - Phase 4d.1d: full YG10 decode (Y + A + Co + Cg)

    /// Phase 4d.1d: decode the YG10 packet end-to-end.
    /// Two cocg passes: first emits Y + alpha BC5 blocks (16 bytes
    /// per 4×4 tile, two BC4 halves), second emits Co + Cg BC5
    /// blocks (same as YCG6 chroma).
    ///
    /// FFmpeg mapping:
    ///   First call:  op_data[0] (Y opcodes)     + op_data[3] (alpha opcodes)
    ///                op_size[0]                  + op_size[3]
    ///                writes to tex_data (size: w/4 × h/4 × 16)
    ///   Second call: op_data[1] (Co opcodes)    + op_data[2] (Cg opcodes)
    ///                op_size[1]                  + op_size[2]
    ///                writes to ctex_data (size: w/8 × h/8 × 16)
    public static func decompressYG10(
        payload: Data, codedWidth: Int, codedHeight: Int
    ) throws -> YG10Result {
        let (texSize, ctexSize, opSizes) = computeBufferSizes(
            codedWidth: codedWidth, codedHeight: codedHeight, variant: .yg10)

        // Materialize payload + 4-byte padding for bitstream walker.
        var payloadBytes = Array(payload)
        payloadBytes.append(contentsOf: [0, 0, 0, 0])

        // -------- Pass 1: cocg(Y + alpha) → tex_data --------
        var cursor = 0
        guard cursor + 12 <= payloadBytes.count else {
            throw DecodeError.truncatedInput(
                needed: 12, available: payloadBytes.count - cursor, where: "yg10 pass1 cocg header")
        }
        let opOffset0 = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let opSizeY = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let opSizeA = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let dataStart0 = cursor

        if opOffset0 < 12 || opOffset0 - 12 > payloadBytes.count - cursor {
            throw DecodeError.invalidOpOffset(opOffset0)
        }
        // YG10 maps op_size[0] = Y, op_size[3] = A.
        if opSizeY > opSizes[0] {
            throw DecodeError.opSizeExceedsMax(opSize: opSizeY, max: opSizes[0])
        }
        if opSizeA > opSizes[3] {
            throw DecodeError.opSizeExceedsMax(opSize: opSizeA, max: opSizes[3])
        }

        // Decompress Y opcodes then alpha opcodes (channel 0 then 1
        // of the BC5 block in this pass).
        var opcodeCursor = cursor + (opOffset0 - 12)
        let opResultY = try DXVHQOpcodeDecoder.decompressOpcodesArray(
            input: payloadBytes, offset: opcodeCursor, opSize: opSizeY)
        opcodeCursor += opResultY.bytesConsumed
        let opDataY = Array(opResultY.opcodes)

        let opResultA = try DXVHQOpcodeDecoder.decompressOpcodesArray(
            input: payloadBytes, offset: opcodeCursor, opSize: opSizeA)
        let opDataA = Array(opResultA.opcodes)

        // Run cocg state machine for Y + alpha.
        var texData = [UInt8](repeating: 0, count: texSize)
        let cocgYAStart = Date()
        try texData.withUnsafeMutableBufferPointer { texPtr in
            _ = try DXVHQCgoDecoder.runCocgStateMachine(
                payload: payloadBytes,
                dataStart: dataStart0,
                texData: texPtr.baseAddress!,
                texSize: texSize,
                opData0: opDataY, opSize0: opSizeY,
                opData1: opDataA, opSize1: opSizeA)
        }
        let cocgYAMs = Date().timeIntervalSince(cocgYAStart) * 1000

        // BC5-unpack Y + A planes. By analogy with YCG6 chroma where
        // the first half of each BC5 block holds Cg (V) and the
        // second holds Co (U), we expect the YG10 luma+alpha BC5
        // blocks to have alpha in the first half and Y in the second
        // half — matching FFmpeg's pix_fmt=YUVA420P planar order
        // (Y, U, V, A). However this convention isn't documented and
        // the diagnostic dump will tell us if we got it right; if Y
        // and A are swapped we'll see it in the validation output.
        let bc5YAStart = Date()
        var y = [UInt8](repeating: 0, count: codedWidth * codedHeight)
        var a = [UInt8](repeating: 0, count: codedWidth * codedHeight)
        texData.withUnsafeBufferPointer { texPtr in
            // First guess: channel 0 = Y, channel 1 = A. If validation
            // shows a swap, we'll flip.
            y.withUnsafeMutableBufferPointer { yPtr in
                a.withUnsafeMutableBufferPointer { aPtr in
                    BC4BC5Unpack.unpackBC5Plane(
                        blocks: texPtr.baseAddress!,
                        blocksCount: texSize / 16,
                        outputChannel0: yPtr.baseAddress!,
                        outputChannel1: aPtr.baseAddress!,
                        width: codedWidth, height: codedHeight)
                }
            }
        }
        let bc5YAMs = Date().timeIntervalSince(bc5YAStart) * 1000

        // Advance cursor past pass 1's data + opcodes.
        let postPass1Cursor = dataStart0 + opOffset0
                            + opResultY.bytesConsumed
                            + opResultA.bytesConsumed
                            - 12

        // -------- Pass 2: cocg(Co + Cg) → ctex_data --------
        cursor = postPass1Cursor
        guard cursor + 12 <= payloadBytes.count else {
            throw DecodeError.truncatedInput(
                needed: 12, available: payloadBytes.count - cursor, where: "yg10 pass2 cocg header")
        }
        let opOffset1 = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let opSizeCo = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let opSizeCg = Int(readLE32Bytes(payloadBytes, cursor))
        cursor += 4
        let dataStart1 = cursor

        if opOffset1 < 12 || opOffset1 - 12 > payloadBytes.count - cursor {
            throw DecodeError.invalidOpOffset(opOffset1)
        }
        // YG10 maps op_size[1] = Co, op_size[2] = Cg.
        if opSizeCo > opSizes[1] {
            throw DecodeError.opSizeExceedsMax(opSize: opSizeCo, max: opSizes[1])
        }
        if opSizeCg > opSizes[2] {
            throw DecodeError.opSizeExceedsMax(opSize: opSizeCg, max: opSizes[2])
        }

        opcodeCursor = cursor + (opOffset1 - 12)
        let opResultCo = try DXVHQOpcodeDecoder.decompressOpcodesArray(
            input: payloadBytes, offset: opcodeCursor, opSize: opSizeCo)
        opcodeCursor += opResultCo.bytesConsumed
        let opDataCo = Array(opResultCo.opcodes)

        let opResultCg = try DXVHQOpcodeDecoder.decompressOpcodesArray(
            input: payloadBytes, offset: opcodeCursor, opSize: opSizeCg)
        let opDataCg = Array(opResultCg.opcodes)

        var ctexData = [UInt8](repeating: 0, count: ctexSize)
        let cocgCoCgStart = Date()
        try ctexData.withUnsafeMutableBufferPointer { ctexPtr in
            _ = try DXVHQCgoDecoder.runCocgStateMachine(
                payload: payloadBytes,
                dataStart: dataStart1,
                texData: ctexPtr.baseAddress!,
                texSize: ctexSize,
                opData0: opDataCo, opSize0: opSizeCo,
                opData1: opDataCg, opSize1: opSizeCg)
        }
        let cocgCoCgMs = Date().timeIntervalSince(cocgCoCgStart) * 1000

        // BC5-unpack Co + Cg. Same convention as YCG6 chroma: first
        // half = Co (channel 0), second half = Cg (channel 1).
        // Confirmed semantically correct by visual rendering test
        // in 4d.2.
        let chromaW = codedWidth / 2
        let chromaH = codedHeight / 2
        let bc5CoCgStart = Date()
        var co = [UInt8](repeating: 0, count: chromaW * chromaH)
        var cg = [UInt8](repeating: 0, count: chromaW * chromaH)
        ctexData.withUnsafeBufferPointer { ctexPtr in
            co.withUnsafeMutableBufferPointer { coPtr in
                cg.withUnsafeMutableBufferPointer { cgPtr in
                    BC4BC5Unpack.unpackBC5Plane(
                        blocks: ctexPtr.baseAddress!,
                        blocksCount: ctexSize / 16,
                        outputChannel0: coPtr.baseAddress!,   // first half = Co
                        outputChannel1: cgPtr.baseAddress!,   // second half = Cg
                        width: chromaW, height: chromaH)
                }
            }
        }
        let bc5CoCgMs = Date().timeIntervalSince(bc5CoCgStart) * 1000

        return YG10Result(
            y: y, a: a, co: co, cg: cg,
            width: codedWidth, height: codedHeight,
            chromaWidth: chromaW, chromaHeight: chromaH,
            cocgYAMs: cocgYAMs, bc5YAMs: bc5YAMs,
            cocgCoCgMs: cocgCoCgMs, bc5CoCgMs: bc5CoCgMs)
    }

    // MARK: - Helpers (private)

    /// Read LE32 from a byte array (zero-indexed).
    private static func readLE32Bytes(_ data: [UInt8], _ off: Int) -> UInt32 {
        return UInt32(data[off])
            | (UInt32(data[off + 1]) << 8)
            | (UInt32(data[off + 2]) << 16)
            | (UInt32(data[off + 3]) << 24)
    }

    /// dxv_decompress_yo prelude: reads op_offset and op_size, jumps to
    /// the opcode block, decompresses it, then would normally seek
    /// back to data_start to begin emitting tex blocks. For 4d.1a we
    /// stop after extracting opcodes (4d.1b adds the cgo state
    /// machine).
    private static func runYoPrelude(
        payload: Data, cursor: inout Int,
        texSize: Int, maxOpSize: Int,
        extractedOpcodes: inout [Data],
        bytesConsumed: inout [Int]
    ) throws {
        guard cursor + 8 <= payload.count else {
            throw DecodeError.truncatedInput(
                needed: 8, available: payload.count - cursor, where: "yo prelude")
        }
        let opOffset = Int(readLE32(payload, cursor))
        cursor += 4
        let opSize = Int(readLE32(payload, cursor))
        cursor += 4
        let dataStart = cursor

        if opOffset < 8 || opOffset - 8 > payload.count - cursor {
            throw DecodeError.invalidOpOffset(opOffset)
        }
        // Skip to the opcode block.
        cursor += opOffset - 8

        if opSize > maxOpSize {
            throw DecodeError.opSizeExceedsMax(opSize: opSize, max: maxOpSize)
        }
        let result = try DXVHQOpcodeDecoder.decompressOpcodes(
            input: payload, offset: cursor, opSize: opSize)
        extractedOpcodes.append(result.opcodes)
        bytesConsumed.append(result.bytesConsumed)
        cursor += result.bytesConsumed

        // FFmpeg seeks back to data_start to begin emitting tex blocks.
        // We mirror by resetting cursor for any caller that wants to
        // continue. For 4d.1a we instead jump the cursor PAST the data
        // section so the next prelude (cocg) starts at the right place.
        //
        // Per FFmpeg line 634: bytestream2_seek(data_start + op_offset
        // + skip - 8). That's the position immediately after the
        // opcode bitstream, which is also where the next yo/cocg
        // prelude (or the next packet data) begins. For 4d.1a the
        // simplest correct behavior is: cursor is already there
        // because we read 8 bytes (opOffset+opSize), then skipped
        // (opOffset - 8), then consumed `bytesConsumed`. Total =
        // 8 + (opOffset - 8) + bytesConsumed = opOffset + bytesConsumed
        // from dataStart - 8. Same as FFmpeg's `data_start + op_offset
        // + skip - 8` because cursor at entry was data_start - 8 (we
        // were 8 bytes before dataStart at the start of the function).
        _ = dataStart  // keep variable name parity with FFmpeg for review
    }

    /// dxv_decompress_cocg prelude: reads op_offset and TWO op_size
    /// values (one per of the two chroma streams), jumps to the
    /// opcode block, decompresses both opcode buffers in sequence.
    private static func runCocgPrelude(
        payload: Data, cursor: inout Int,
        texSize: Int,
        maxOpSize0: Int, maxOpSize1: Int,
        extractedOpcodes: inout [Data],
        bytesConsumed: inout [Int]
    ) throws {
        guard cursor + 12 <= payload.count else {
            throw DecodeError.truncatedInput(
                needed: 12, available: payload.count - cursor, where: "cocg prelude")
        }
        let opOffset = Int(readLE32(payload, cursor))
        cursor += 4
        let opSize0 = Int(readLE32(payload, cursor))
        cursor += 4
        let opSize1 = Int(readLE32(payload, cursor))
        cursor += 4
        let dataStart = cursor

        if opOffset < 12 || opOffset - 12 > payload.count - cursor {
            throw DecodeError.invalidOpOffset(opOffset)
        }
        cursor += opOffset - 12

        if opSize0 > maxOpSize0 {
            throw DecodeError.opSizeExceedsMax(opSize: opSize0, max: maxOpSize0)
        }
        let result0 = try DXVHQOpcodeDecoder.decompressOpcodes(
            input: payload, offset: cursor, opSize: opSize0)
        extractedOpcodes.append(result0.opcodes)
        bytesConsumed.append(result0.bytesConsumed)
        cursor += result0.bytesConsumed

        if opSize1 > maxOpSize1 {
            throw DecodeError.opSizeExceedsMax(opSize: opSize1, max: maxOpSize1)
        }
        let result1 = try DXVHQOpcodeDecoder.decompressOpcodes(
            input: payload, offset: cursor, opSize: opSize1)
        extractedOpcodes.append(result1.opcodes)
        bytesConsumed.append(result1.bytesConsumed)
        cursor += result1.bytesConsumed
        _ = dataStart
    }

    private static func readLE32(_ data: Data, _ off: Int) -> UInt32 {
        let base = data.startIndex + off
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
