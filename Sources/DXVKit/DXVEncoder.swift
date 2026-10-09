// DXVKit Swift encoder API over the C core.
//
//   let enc = try DXVEncoder(variant: .ycg6, width: 1920, height: 1080,
//                            options: DXVEncodeOptions(effort: .best, parallel: true))
//   let packet = try enc.encode(rgba: pixels, bytesPerRow: 1920 * 4)   // one DXV3 frame
//   let writer = try DXVMovieWriter(url: out, width: 1920, height: 1080, timescale: 30000, frameDuration: 1001)
//   try writer.append(packet); try writer.finish()
//
// MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.

import CDXVKit
import Dispatch
import Foundation

public enum DXVEffort: Sendable {
    /// Live / batch: principal-axis BC1, min/max BC4, one opcode pass.
    case fast
    /// Archive: refined BCn endpoint search, larger match tables, two opcode passes.
    case best
}

public enum DXVOpcodeCoding: Sendable {
    /// Per stream the smallest of FSE / stored / fill (what Resolume writes).
    case auto
    /// Stored / fill only (no entropy coding).
    case stored
}

public struct DXVEncodeOptions: Sendable {
    public var effort: DXVEffort
    public var opcodes: DXVOpcodeCoding
    /// The input colour is premultiplied and is written as such (default: straight, like Alley).
    /// The packet bytes do not change: the file has no field for the convention.
    public var premultipliedInput: Bool
    /// DXT1 / DXT5 only: stored-flag packets (valid, never seen in real files).
    public var storedPayload: Bool
    /// Spread BCn compression and the two HQ sections over Dispatch's concurrent pool.
    public var parallel: Bool

    public init(effort: DXVEffort = .fast, opcodes: DXVOpcodeCoding = .auto, premultipliedInput: Bool = false,
                storedPayload: Bool = false, parallel: Bool = false) {
        self.effort = effort
        self.opcodes = opcodes
        self.premultipliedInput = premultipliedInput
        self.storedPayload = storedPayload
        self.parallel = parallel
    }
}

private func encoderJobs(_: UnsafeMutableRawPointer?,
                         _ job: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Void)?,
                         _ arg: UnsafeMutableRawPointer?, _ count: Int32) {
    guard let job else { return }
    DispatchQueue.concurrentPerform(iterations: Int(count)) { job(arg, Int32($0)) }
}

/// Encoder for one DXV3 variant and frame size. All memory is allocated at init; encoding allocates
/// only the returned packet. Not thread-safe: one encoder per encoding thread.
public final class DXVEncoder {
    private let enc: OpaquePointer
    private let jobs: UnsafeMutablePointer<dxvk_jobs>
    public let variant: DXVVariant
    public let width: Int, height: Int
    public let layout: DXVLayout
    /// Largest packet this encoder can produce.
    public let maxPacketSize: Int
    private var buffer: [UInt8]

    public init(variant: DXVVariant, width: Int, height: Int, options: DXVEncodeOptions = DXVEncodeOptions()) throws {
        jobs = .allocate(capacity: 1)
        jobs.initialize(to: dxvk_jobs(run: encoderJobs, user: nil))
        var flags: UInt32 = 0
        if options.premultipliedInput { flags |= UInt32(DXVK_ENC_PREMULTIPLIED_INPUT) }
        if options.storedPayload { flags |= UInt32(DXVK_ENC_STORED_PAYLOAD) }
        var opt = dxvk_encode_options(flags: flags,
                                      effort: options.effort == .best ? DXVK_EFFORT_BEST : DXVK_EFFORT_FAST,
                                      opcodes: options.opcodes == .stored ? DXVK_OPCODES_STORED : DXVK_OPCODES_AUTO,
                                      jobs: options.parallel ? UnsafePointer(jobs) : nil)
        var e: OpaquePointer?
        let status = dxvk_encoder_create(variant.c, UInt32(clamping: width), UInt32(clamping: height), &opt, &e)
        guard status == DXVK_OK, let e else {
            jobs.deallocate()
            throw DXVError(status)
        }
        enc = e
        self.variant = variant
        self.width = width
        self.height = height
        layout = DXVLayout(dxvk_encoder_layout(e)!.pointee)
        maxPacketSize = dxvk_encode_bound(variant.c, UInt32(width), UInt32(height))
        buffer = [UInt8](repeating: 0, count: maxPacketSize)
    }

    deinit {
        dxvk_encoder_destroy(enc)
        jobs.deallocate()
    }

    /// RGBA8 at the display size (rows top first) -> one DXV3 packet.
    public func encode(rgba: UnsafeRawPointer, bytesPerRow: Int) throws -> Data {
        var n = 0
        let status = buffer.withUnsafeMutableBytes { out in
            dxvk_encoder_encode(enc, rgba.assumingMemoryBound(to: UInt8.self), bytesPerRow,
                                out.baseAddress, out.count, &n)
        }
        if status != DXVK_OK { throw DXVError(status) }
        return Data(buffer[0..<n])
    }

    /// RGBA8 in Data (tightly packed rows) -> one DXV3 packet.
    public func encode(rgba: Data) throws -> Data {
        guard rgba.count >= width * height * 4 else { throw DXVError(DXVK_ERR_ARGUMENT) }
        return try rgba.withUnsafeBytes { try encode(rgba: $0.baseAddress!, bytesPerRow: width * 4) }
    }

    /// Blocks-in path: block planes in `layout` (plane 0, and plane 1 for YCG6 / YG10) -> packet.
    public func pack(plane0: UnsafeRawPointer, plane1: UnsafeRawPointer? = nil) throws -> Data {
        var planes: (UnsafeRawPointer?, UnsafeRawPointer?) = (plane0, plane1)
        var n = 0
        let status = withUnsafePointer(to: &planes) { pp in
            pp.withMemoryRebound(to: UnsafeRawPointer?.self, capacity: 2) { p2 in
                buffer.withUnsafeMutableBytes { out in
                    dxvk_encoder_pack(enc, p2, out.baseAddress, out.count, &n)
                }
            }
        }
        if status != DXVK_OK { throw DXVError(status) }
        return Data(buffer[0..<n])
    }

    /// The block planes packed by the last `encode` (nil before the first one).
    public func withPackedPlane<R>(_ index: Int, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R? {
        guard index < layout.planes.count, let p = dxvk_encoder_plane(enc, Int32(index)) else { return nil }
        return try body(UnsafeRawBufferPointer(start: p, count: layout.planes[index].byteCount))
    }
}

/// Writes a .mov with one DXV3 ('DXD3') video track. Audio is the caller's job.
public final class DXVMovieWriter {
    private var writer: OpaquePointer?

    public init(url: URL, width: Int, height: Int, timescale: Int, frameDuration: Int) throws {
        var w: OpaquePointer?
        let status = url.withUnsafeFileSystemRepresentation {
            dxvk_mov_writer_open_file($0, UInt32(clamping: width), UInt32(clamping: height),
                                      UInt32(clamping: timescale), UInt32(clamping: frameDuration), &w)
        }
        if status != DXVK_OK { throw DXVError(status) }
        writer = w
    }

    deinit { dxvk_mov_writer_close(writer) }

    /// Appends one packet (one frame); every packet of a file must have the same variant.
    public func append(_ packet: Data) throws {
        let status = packet.withUnsafeBytes { dxvk_mov_writer_add(writer, $0.baseAddress, $0.count) }
        if status != DXVK_OK { throw DXVError(status) }
    }

    /// Writes the movie header and sample tables; the file is complete afterwards.
    public func finish() throws {
        let status = dxvk_mov_writer_finish(writer)
        if status != DXVK_OK { throw DXVError(status) }
        dxvk_mov_writer_close(writer)
        writer = nil
    }
}
