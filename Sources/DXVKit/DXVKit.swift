// DXVKit Swift wrapper over the C core.
//
//   let movie = try DXVMovie(url: url)
//   movie.frameCount, movie.width, movie.height, movie.variant, movie.frameRate
//   let frame = DXVFrame()                         // reusable buffers, grow once
//   try movie.decodeBlocks(at: n, into: frame)     // BCn block streams (GPU upload)
//   frame.withPlane(0) { bytes in ... }            // plane 0: BC1 / BC3 / BC4 Y / BC5 Y+A
//   let rgba = try movie.decodeRGBA(at: n)         // CPU path, display size, RGBA8
//
// MIT License. Copyright (c) 2026 Amrit Rosell. See LICENSE.

import CDXVKit
import Dispatch
import Foundation

/// DXVKit's version (the release tag, e.g. "1.0.0"); `DXVKitLibraryVersion` is the linked C core's.
public let DXVKitVersion = "1.0.0"
public var DXVKitLibraryVersion: String { String(cString: dxvk_version_string()) }

public struct DXVError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public var description: String { String(cString: dxvk_status_string(dxvk_status(rawValue: UInt32(code)))) }
    init(_ status: dxvk_status) { code = Int32(status.rawValue) }
}

@inline(__always)
private func check(_ status: dxvk_status) throws {
    if status != DXVK_OK { throw DXVError(status) }
}

public enum DXVVariant: Int, CaseIterable, Sendable {
    case dxt1 = 0, dxt5, ycg6, yg10, legacyDXT1, legacyDXT5

    init(_ v: dxvk_variant) { self = DXVVariant(rawValue: Int(v.rawValue)) ?? .dxt1 }
    var c: dxvk_variant { dxvk_variant(rawValue: UInt32(rawValue)) }

    public var name: String { String(cString: dxvk_variant_name(c)) }
    public var hasAlpha: Bool { dxvk_variant_has_alpha(c) != 0 }
    /// High Quality variants carry two planes (luma[+alpha] and Co/Cg chroma).
    public var isHighQuality: Bool { self == .ycg6 || self == .yg10 }
}

public enum DXVBlockFormat: Int, Sendable {
    case none = 0, bc1, bc3, bc4, bc5
}

/// One block-stream plane: blocks row by row, top row first, covering the coded (16-padded) texture.
public struct DXVPlane: Sendable {
    public let format: DXVBlockFormat
    public let width: Int, height: Int          // in pixels (plane 1: chroma samples)
    public let blocksX: Int, blocksY: Int
    public let byteCount: Int
}

public struct DXVLayout: Sendable {
    public let variant: DXVVariant
    public let displayWidth: Int, displayHeight: Int
    public let codedWidth: Int, codedHeight: Int
    public let planes: [DXVPlane]

    init(_ l: dxvk_frame_layout) {
        variant = DXVVariant(l.variant)
        displayWidth = Int(l.display_width)
        displayHeight = Int(l.display_height)
        codedWidth = Int(l.coded_width)
        codedHeight = Int(l.coded_height)
        let fmt = [l.format.0, l.format.1], bx = [l.blocks_x.0, l.blocks_x.1], by = [l.blocks_y.0, l.blocks_y.1]
        let px = [l.pixels_x.0, l.pixels_x.1], py = [l.pixels_y.0, l.pixels_y.1], bytes = [l.bytes.0, l.bytes.1]
        planes = (0..<Int(l.plane_count)).map { i in
            DXVPlane(format: DXVBlockFormat(rawValue: Int(fmt[i].rawValue)) ?? .none,
                     width: Int(px[i]), height: Int(py[i]), blocksX: Int(bx[i]), blocksY: Int(by[i]),
                     byteCount: bytes[i])
        }
    }

    public init(variant: DXVVariant, width: Int, height: Int) throws {
        var l = dxvk_frame_layout()
        try check(dxvk_layout(variant.c, UInt32(clamping: width), UInt32(clamping: height), &l))
        self.init(l)
    }
}

/// Decode options: straight -> premultiplied alpha for the RGBA path, and whether to spread the HQ
/// planes / RGBA conversion over Dispatch's concurrent pool.
public struct DXVOptions: Sendable {
    public var premultiply: Bool
    public var parallel: Bool
    public init(premultiply: Bool = false, parallel: Bool = false) {
        self.premultiply = premultiply
        self.parallel = parallel
    }
}

private func dispatchJobs(_: UnsafeMutableRawPointer?,
                          _ job: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Void)?,
                          _ arg: UnsafeMutableRawPointer?, _ count: Int32) {
    guard let job else { return }
    DispatchQueue.concurrentPerform(iterations: Int(count)) { job(arg, Int32($0)) }
}

private func withCOptions<R>(_ o: DXVOptions, _ body: (UnsafePointer<dxvk_options>) throws -> R) rethrows -> R {
    var jobs = dxvk_jobs(run: dispatchJobs, user: nil)
    return try withUnsafePointer(to: &jobs) { jp in
        var opt = dxvk_options(flags: o.premultiply ? UInt32(DXVK_OPT_PREMULTIPLY) : 0,
                               jobs: o.parallel ? jp : nil)
        return try withUnsafePointer(to: &opt) { try body($0) }
    }
}

/// Reusable decode target: owns the block-stream buffers of one frame. Not thread-safe; use one per
/// decoding thread.
public final class DXVFrame {
    public private(set) var layout: DXVLayout?
    private var raw = dxvk_frame_layout()
    private var buffers: [UnsafeMutableRawPointer?] = [nil, nil]
    private var capacity: [Int] = [0, 0]

    public init() {}
    deinit { buffers.forEach { $0?.deallocate() } }

    fileprivate func reserve(width: UInt32, height: UInt32) throws {
        var big = dxvk_frame_layout()
        try check(dxvk_layout(DXVK_VARIANT_YG10, width, height, &big))
        let need = [big.bytes.0, big.bytes.1]
        for i in 0..<2 where capacity[i] < need[i] {
            buffers[i]?.deallocate()
            buffers[i] = UnsafeMutableRawPointer.allocate(byteCount: need[i], alignment: 64)
            capacity[i] = need[i]
        }
    }

    /// Decodes one packet (bytes of one QuickTime sample) into this frame.
    public func decode(packet: UnsafeRawBufferPointer, generation: DXVGeneration, width: Int, height: Int,
                       options: DXVOptions = DXVOptions()) throws {
        try reserve(width: UInt32(clamping: width), height: UInt32(clamping: height))
        var planes: (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) = (buffers[0], buffers[1])
        var caps: (Int, Int) = (capacity[0], capacity[1])
        var l = dxvk_frame_layout()
        let status = withCOptions(options) { opt in
            withUnsafePointer(to: &planes) { pp in
                withUnsafePointer(to: &caps) { cp in
                    pp.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 2) { p2 in
                        cp.withMemoryRebound(to: Int.self, capacity: 2) { c2 in
                            dxvk_decode_blocks(generation.c, packet.baseAddress, packet.count,
                                               UInt32(clamping: width), UInt32(clamping: height), opt,
                                               p2, c2, &l, nil)
                        }
                    }
                }
            }
        }
        try check(status)
        raw = l
        layout = DXVLayout(l)
    }

    /// Read access to a decoded plane's block stream (exactly layout.planes[i].byteCount bytes).
    public func withPlane<R>(_ index: Int, _ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        precondition(layout != nil && index < layout!.planes.count, "no such plane")
        return try body(UnsafeRawBufferPointer(start: buffers[index], count: layout!.planes[index].byteCount))
    }

    /// RGBA8 at the display size into caller memory (bytesPerRow >= displayWidth * 4).
    /// YCG6 / YG10 follow Resolume Arena's convention (exact BC4 palettes, nearest chroma, chroma
    /// midpoint 127.5, R / B overflow folding); DXT1 / DXT5 the spec's integer BC1 / BC3 convention.
    public func convertToRGBA(into destination: UnsafeMutableRawPointer, bytesPerRow: Int,
                              options: DXVOptions = DXVOptions()) throws {
        guard layout != nil else { throw DXVError(DXVK_ERR_ARGUMENT) }
        var planes: (UnsafeRawPointer?, UnsafeRawPointer?) = (UnsafeRawPointer(buffers[0]), UnsafeRawPointer(buffers[1]))
        let status = withCOptions(options) { opt in
            withUnsafePointer(to: &planes) { pp in
                pp.withMemoryRebound(to: UnsafeRawPointer?.self, capacity: 2) { p2 in
                    dxvk_blocks_to_rgba(&raw, p2, opt, destination.assumingMemoryBound(to: UInt8.self), bytesPerRow)
                }
            }
        }
        try check(status)
    }

    /// RGBA8 at the display size as Data (tightly packed rows).
    public func rgba(options: DXVOptions = DXVOptions()) throws -> Data {
        guard let l = layout else { throw DXVError(DXVK_ERR_ARGUMENT) }
        var out = Data(count: l.displayWidth * l.displayHeight * 4)
        try out.withUnsafeMutableBytes { try convertToRGBA(into: $0.baseAddress!, bytesPerRow: l.displayWidth * 4, options: options) }
        return out
    }
}

/// The container's generation (a hint). Since 1.0 the packet decides, as Resolume Arena does: a packet
/// that starts with a DXV3 texture tag is DXV3, any other is legacy; all three values decode the same.
public enum DXVGeneration: Sendable {
    case dxv3, legacy, auto
    var c: dxvk_generation {
        switch self {
        case .dxv3: return DXVK_GEN_DXV3
        case .legacy: return DXVK_GEN_LEGACY
        case .auto: return DXVK_GEN_AUTO
        }
    }
}

/// An open DXV QuickTime file. Thread-safe (packet reads are serialised internally).
public final class DXVMovie: @unchecked Sendable {
    private let mov: OpaquePointer
    private let lock = NSLock()
    private var packet: [UInt8] = []
    private let backing: Data?                  // keeps in-memory files alive

    public let generation: DXVGeneration
    public let width: Int, height: Int
    public let frameCount: Int
    public let frameRate: Double
    public let timescale: Int, frameDuration: Int
    public let maxPacketSize: Int
    /// Variant of the first packet (every packet is still checked when decoded).
    public let variant: DXVVariant
    public var hasAlpha: Bool { variant.hasAlpha }

    public convenience init(url: URL) throws {
        var m: OpaquePointer?
        try check(url.withUnsafeFileSystemRepresentation { dxvk_mov_open_file($0, &m) })
        try self.init(handle: m!, backing: nil)
    }

    public convenience init(data: Data) throws {
        var m: OpaquePointer?
        let copy = Data(data) // stable storage owned by this object
        try check(copy.withUnsafeBytes { dxvk_mov_open_memory($0.baseAddress, $0.count, &m) })
        try self.init(handle: m!, backing: copy)
    }

    private init(handle: OpaquePointer, backing: Data?) throws {
        mov = handle
        self.backing = backing
        let info = dxvk_mov_get_info(handle)!.pointee
        generation = info.generation == DXVK_GEN_LEGACY ? .legacy : .dxv3
        width = Int(info.width)
        height = Int(info.height)
        frameCount = Int(info.frame_count)
        frameRate = info.frame_rate
        timescale = Int(info.timescale)
        frameDuration = Int(info.frame_duration)
        maxPacketSize = Int(info.max_packet_size)
        packet = [UInt8](repeating: 0, count: maxPacketSize)
        var n = 0
        var v = DXVK_VARIANT_DXT1
        var status = dxvk_mov_read_packet(handle, 0, &packet, packet.count, &n)
        if status == DXVK_OK { status = dxvk_packet_variant(info.generation, packet, n, &v, nil) }
        if status != DXVK_OK {
            dxvk_mov_close(handle)
            throw DXVError(status)
        }
        variant = DXVVariant(v)
    }

    deinit { dxvk_mov_close(mov) }

    public var layout: DXVLayout { get throws { try DXVLayout(variant: variant, width: width, height: height) } }

    /// The raw bytes of sample `index`.
    public func packet(at index: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var n = 0
        try check(dxvk_mov_read_packet(mov, UInt32(clamping: index), &packet, packet.count, &n))
        return Data(packet[0..<n])
    }

    /// Decodes frame `index` into `frame`'s block-stream buffers.
    public func decodeBlocks(at index: Int, into frame: DXVFrame, options: DXVOptions = DXVOptions()) throws {
        guard index >= 0 && index < frameCount else { throw DXVError(DXVK_ERR_RANGE) }
        lock.lock(); defer { lock.unlock() }
        var n = 0
        try check(dxvk_mov_read_packet(mov, UInt32(index), &packet, packet.count, &n))
        try packet.withUnsafeBytes { buf in
            try frame.decode(packet: UnsafeRawBufferPointer(rebasing: buf[0..<n]), generation: generation,
                             width: width, height: height, options: options)
        }
    }

    /// Decodes frame `index` to RGBA8 (display size, tightly packed).
    public func decodeRGBA(at index: Int, options: DXVOptions = DXVOptions()) throws -> Data {
        let frame = DXVFrame()
        try decodeBlocks(at: index, into: frame, options: options)
        return try frame.rgba(options: options)
    }
}
