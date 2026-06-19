// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation
import QuartzCore
import GlanceCore

/// DXV file player — orchestrates demux, decode, and (in later phases)
/// GPU upload + render for DXV3 files. Phase 4c.1 was decode-only for
/// DXT1/DXT5; Phase 4c.2 wired this to DXVRenderer; Phase 4d.3 adds
/// the HQ variants (YCG6, YG10) using the byte-validated HQ decoder.
///
/// Threading model:
/// - Public API runs on main (matches PlayerModel/SwiftUI).
/// - File reads happen on a serial dispatch queue dedicated to this
///   player so disk I/O doesn't block main during scrubs.
/// - Decode runs on the same queue so frame ordering is preserved.
/// - Decoded frame callbacks hop back to main.
///
/// Lifecycle:
///   let player = try DXVPlayer(url: someURL)
///   player.onFrameDecoded = { idx, dxtBytes, decodeTimeMs in ... }     // DXT path
///   player.onHQFrameDecoded = { idx, hqFrame, decodeTimeMs in ... }    // HQ path
///   player.play()
///   ... later ...
///   player.pause() / player.seek(to:) / player.stop()
public final class DXVPlayer {
    public let url: URL
    public let index: DXVMovieIndex
    public let clock: FrameClock

    /// Called on main thread when a new DXT1/DXT5 frame has been
    /// decoded. Receives the frame index, the DXT-compressed bytes
    /// ready for GPU upload, and the decode time in milliseconds
    /// (for diagnostics). Only fires for DXT variants.
    ///
    /// `dxtBytes` is sized for the **padded** 16-pixel-aligned width
    /// layout (`paddedWidth * height / 2` DXT1, `paddedWidth * height`
    /// DXT5). `DXVRenderer.uploadFrame` knows about this — callers
    /// hand it the **display** width/height and the renderer pads
    /// internally. Don't try to compute display-width-sized buffers
    /// here; the encoder/decoder chain only works against the padded
    /// layout for non-16-aligned widths.
    public var onFrameDecoded: ((_ frameIndex: Int, _ dxtBytes: Data, _ decodeMs: Double) -> Void)?

    /// Called on main thread when a new YCG6/YG10 frame has been
    /// decoded. Receives the frame index, the four planes packaged
    /// in HQFrameData, and the decode time in milliseconds. Only
    /// fires for HQ variants.
    public var onHQFrameDecoded: ((_ frameIndex: Int, _ frame: DXVRenderer.HQFrameData, _ decodeMs: Double) -> Void)?

    /// Called on main thread when decode fails for a frame. Player keeps
    /// running on the next frame; this is for logging.
    public var onDecodeError: ((_ frameIndex: Int, _ error: Error) -> Void)?

    /// Called on main thread periodically with running performance
    /// stats. Receives (decoded frames in window, mean decode ms,
    /// max decode ms, dropped frames). Use for the diagnostic gate.
    public var onStats: ((_ stats: Stats) -> Void)?

    public struct Stats {
        public let frameCount: Int
        public let meanDecodeMs: Double
        public let maxDecodeMs: Double
        public let dropped: Int
        public let windowSeconds: Double
        public var summary: String {
            String(format: "%.0f frames in %.1fs — mean=%.2fms max=%.2fms dropped=%d",
                   Double(frameCount), windowSeconds,
                   meanDecodeMs, maxDecodeMs, dropped)
        }
    }

    // MARK: - Internals

    private let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "com.amritus.glance.dxvplayer", qos: .userInteractive)

    /// In-flight tracking. When the clock asks for frame N but we're
    /// still decoding frame N-1, we drop N-1 and skip to N. This avoids
    /// stacking up work during scrubs.
    private var pendingFrame: Int? = nil
    private var inFlight = false

    /// Stats window — accumulates decode times for the last `windowSize`
    /// frames, reports periodically.
    private var statsTimes: [Double] = []
    private var statsDropped: Int = 0
    private var lastStatsReport: CFTimeInterval = CACurrentMediaTime()
    private let statsReportInterval: CFTimeInterval = 1.0  // seconds

    public init(url: URL) throws {
        self.url = url
        self.index = try DXVDemuxer.demux(url: url)
        // Phase 4d.3: accept all four DXV3 variants.
        switch index.variant {
        case .dxt1, .dxt5, .ycg6, .yg10:
            break
        }
        guard let firstFrame = index.frames.first, firstFrame.size > 0 else {
            throw NSError(domain: "DXVPlayer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no frames in file"])
        }
        self.fileHandle = try FileHandle(forReadingFrom: url)
        self.clock = FrameClock(
            frameRate: index.frameRate > 0 ? index.frameRate : 30.0,
            totalFrames: index.frames.count)
        // Wire the clock's tick to our decode dispatch.
        self.clock.onFrameChange = { [weak self] frameIdx in
            self?.requestDecode(frame: frameIdx)
        }
    }

    deinit {
        clock.stop()
        try? fileHandle.close()
    }

    // MARK: - Public API

    public func play() {
        print("Glance/player: play() called")
        clock.start()  // safe to call repeatedly
        clock.play()
    }

    public func pause() {
        clock.pause()
    }

    public func togglePause() {
        clock.togglePause()
    }

    public func seek(to frame: Int) {
        clock.seek(to: frame)
    }

    public func stop() {
        clock.stop()
    }

    public var isPaused: Bool { clock.isPaused }
    public var currentFrame: Int { clock.currentFrame }
    public var totalFrames: Int { index.frames.count }
    public var frameRate: Double { index.frameRate }

    // MARK: - Decode pipeline

    /// Request a decode of `frame`. Lock-protected pendingFrame
    /// mechanism: requestDecode (running on main) updates pendingFrame
    /// in place and only enqueues a service block if one isn't already
    /// scheduled. servicePending (running on queue) loops: pull
    /// pendingFrame, decode it, repeat until empty, then clear the
    /// scheduled flag so the next requestDecode re-arms.
    ///
    /// This avoids a previously-observed bug where every requestDecode
    /// posted its own queue.async block — during fast scrubbing, 60+
    /// blocks/s would queue up behind a 16ms decode, and each in turn
    /// would start a fresh decode for ITS (stale) frame number, since
    /// pendingFrame only kicked in for the SECOND-and-later concurrent
    /// block. Net result: ~200ms latency on HQ scrub-and-hold. With
    /// the lock-based design only one block is ever in the queue and
    /// it always processes the latest pending frame; latency stays at
    /// roughly one decode cycle (~16ms HQ, ~10ms DXT).
    private let pendingLock = NSLock()
    /// True when servicePending is enqueued (not yet started) OR a
    /// decode is currently in flight. While true, requestDecode just
    /// updates pendingFrame without enqueueing.
    private var serviceScheduled: Bool = false

    private func requestDecode(frame: Int) {
        pendingLock.lock()
        if pendingFrame != nil {
            // Overwriting a not-yet-decoded request — that frame will
            // never decode. Counts as dropped.
            statsDropped += 1
        }
        pendingFrame = frame
        let needSchedule = !serviceScheduled
        if needSchedule {
            serviceScheduled = true
        }
        pendingLock.unlock()

        if needSchedule {
            queue.async { [weak self] in
                self?.servicePending()
            }
        }
    }

    /// Service the latest pending frame. Runs on `queue` only.
    /// Loops: pull pendingFrame, decode it, then check if more arrived.
    /// Continues until pendingFrame is empty, then clears the
    /// serviceScheduled flag so the next requestDecode re-arms.
    private func servicePending() {
        while true {
            pendingLock.lock()
            guard let frame = pendingFrame else {
                serviceScheduled = false
                pendingLock.unlock()
                return
            }
            pendingFrame = nil
            inFlight = true
            pendingLock.unlock()

            decode(frame: frame)

            pendingLock.lock()
            inFlight = false
            pendingLock.unlock()
        }
    }

    private func decode(frame: Int) {
        // Always on `queue`. State management (inFlight, pendingFrame
        // pickup) is handled by servicePending; this just reads the
        // packet, dispatches to the variant-specific decoder, and
        // surfaces errors.
        guard frame >= 0 && frame < index.frames.count else {
            return
        }
        let entry = index.frames[frame]
        let started = CACurrentMediaTime()

        do {
            try fileHandle.seek(toOffset: entry.fileOffset)
            guard let pkt = try fileHandle.read(upToCount: Int(entry.size)),
                  pkt.count == Int(entry.size) else {
                throw NSError(domain: "DXVPlayer", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "frame \(frame) read short"])
            }
            switch index.variant {
            case .dxt1, .dxt5:
                try decodeDXTFrame(packet: pkt, frame: frame, started: started)
            case .ycg6, .yg10:
                try decodeHQFrame(packet: pkt, frame: frame, started: started)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onDecodeError?(frame, error)
            }
        }
    }

    /// DXT1/DXT5 packet → DXT-compressed bytes (or raw bytes if
    /// rawFlag is set) → onFrameDecoded callback.
    ///
    /// v0.5.0: requests **padded** byte counts from the LZF
    /// decompressor (16-pixel-aligned width). Resolume's encoder pads
    /// BC1/BC3 row data to 16-pixel block alignment internally; asking
    /// for the display-sized count returns mis-aligned bytes that
    /// shear at the right edge for non-aligned widths. Mirrors the
    /// same fix in `DXVThumbnail.decodeDXTPacket` from v0.4.15.
    private func decodeDXTFrame(packet pkt: Data, frame: Int, started: CFTimeInterval) throws {
        let paddedWidth = (index.width + 15) / 16 * 16
        // DXV1's encoder pads BOTH width and height to 16-pixel block
        // alignment; DXV3 pads width only. See the parallel fix in
        // DXVThumbnail.decodeDXTPacket for the observed Metric_01 case.
        let textureHeight: Int
        switch index.generation {
        case .dxv1: textureHeight = (index.height + 15) / 16 * 16
        case .dxv3: textureHeight = index.height
        }
        let dxtSize: Int
        switch index.variant {
        case .dxt1: dxtSize = paddedWidth * textureHeight / 2
        case .dxt5: dxtSize = paddedWidth * textureHeight
        default:
            throw NSError(domain: "DXVPlayer", code: 4)
        }
        let dxtBytes: Data
        switch index.generation {
        case .dxv3:
            let (header, payload) = try DXVPacketDecoder.parseHeader(pkt)
            if header.rawFlag == 1 {
                dxtBytes = payload.prefix(dxtSize)
            } else {
                switch index.variant {
                case .dxt1:
                    dxtBytes = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: dxtSize)
                case .dxt5:
                    dxtBytes = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: dxtSize)
                default:
                    throw NSError(domain: "DXVPlayer", code: 4)
                }
            }
        case .dxv1:
            let (header, payload) = try DXV1PacketDecoder.parseHeader(pkt)
            dxtBytes = try DXV1PacketDecoder.decodePayload(
                payload, header: header, expectedSize: dxtSize)
        }
        let elapsed = (CACurrentMediaTime() - started) * 1000.0
        recordTiming(elapsed)
        DispatchQueue.main.async { [weak self] in
            self?.onFrameDecoded?(frame, dxtBytes, elapsed)
        }
    }

    /// YCG6/YG10 packet → four planes (Y, Co, Cg, optional A) →
    /// onHQFrameDecoded callback. Phase 4d.3.
    ///
    /// Reuses the byte-validated HQ decoder paths from
    /// DXVHQDecoder. For YCG6 we run the luma + chroma decode
    /// separately and bundle the result; for YG10 the single
    /// decompressYG10 call returns all four planes already.
    ///
    /// v0.5.0: passes **padded** (16-pixel-aligned) coded dimensions
    /// to `DXVHQDecoder.*`. Returned planes are at coded dims; the
    /// `HQFrameData` records both display and coded so the renderer
    /// can upload textures at coded and crop to display via UV
    /// scaling. Mirrors `DXVThumbnail.decodeYCG6Packet` /
    /// `decodeYG10Packet` from v0.4.15.
    private func decodeHQFrame(packet pkt: Data, frame: Int, started: CFTimeInterval) throws {
        let (header, payload) = try DXVPacketDecoder.parseHeader(pkt)
        if header.rawFlag == 1 {
            // We have no validation reference for HQ raw packets.
            // Fail loudly so we notice if we ever encounter one in
            // the wild — better than silently producing garbage.
            throw NSError(domain: "DXVPlayer", code: 5, userInfo: [
                NSLocalizedDescriptionKey:
                    "HQ raw frame (rawFlag=1) — not yet supported, please report"])
        }

        let paddedWidth = (index.width + 15) / 16 * 16
        let hqFrame: DXVRenderer.HQFrameData
        switch index.variant {
        case .ycg6:
            let luma = try DXVHQDecoder.decompressYCG6LumaPlane(
                payload: payload,
                codedWidth: paddedWidth, codedHeight: index.height)
            // The chroma sub-packet follows the luma sub-packet in
            // the payload; luma.postCursor tells us where it starts.
            let chroma = try DXVHQDecoder.decompressYCG6ChromaPlane(
                payload: payload, startCursor: luma.postCursor,
                codedWidth: paddedWidth, codedHeight: index.height)
            // Lift result-struct fields (which are `let`) into mutable
            // locals so we can post-process the planes.
            var y = luma.luma
            var co = chroma.co
            var cg = chroma.cg
            // (1) Right-edge: replicate last real column into Y padding
            //     columns so GL_LINEAR blends real-with-real, not
            //     real-with-zero. Chroma untouched: GL_NEAREST snaps
            //     inside the real region.
            if paddedWidth != index.width {
                Self.replicateLastColumn(plane: &y,
                                         displayWidth: index.width,
                                         codedWidth: paddedWidth,
                                         height: index.height)
            }
            // (2) Bottom-edge: HQ decoder works in 4-row blocks; rows
            //     past the last complete block-row stay at the buffer's
            //     initial zero. Replicate the last real row downward so
            //     sampling at v=1.0 returns the real-edge value.
            //     Chroma at half-res — chromaHeight may have 1-3 trailing
            //     zero rows (1138 → 1136 real for the WI11 clip).
            //     Y is at full res; defensive only — most clips have
            //     codedHeight already a multiple of 4.
            let yRealHeight = index.height / 4 * 4
            if yRealHeight < index.height {
                Self.replicateLastRow(plane: &y,
                                      width: paddedWidth,
                                      realHeight: yRealHeight,
                                      bufferHeight: index.height)
            }
            let chromaRealHeight = chroma.chromaHeight / 4 * 4
            if chromaRealHeight < chroma.chromaHeight {
                Self.replicateLastRow(plane: &co,
                                      width: chroma.chromaWidth,
                                      realHeight: chromaRealHeight,
                                      bufferHeight: chroma.chromaHeight)
                Self.replicateLastRow(plane: &cg,
                                      width: chroma.chromaWidth,
                                      realHeight: chromaRealHeight,
                                      bufferHeight: chroma.chromaHeight)
            }
            hqFrame = DXVRenderer.HQFrameData(
                y: y, co: co, cg: cg, a: nil,
                width: index.width, height: index.height,
                codedWidth: paddedWidth, codedHeight: index.height,
                chromaWidth: chroma.chromaWidth, chromaHeight: chroma.chromaHeight)
        case .yg10:
            let result = try DXVHQDecoder.decompressYG10(
                payload: payload,
                codedWidth: paddedWidth, codedHeight: index.height)
            // Same scheme as YCG6 plus alpha. Alpha is full-res +
            // GL_LINEAR (DXVRenderer.swift:315), so it gets the same
            // column + row replication as Y. Co/Cg get the chroma
            // row replication.
            var y = result.y
            var a = result.a
            var co = result.co
            var cg = result.cg
            if paddedWidth != index.width {
                Self.replicateLastColumn(plane: &y,
                                         displayWidth: index.width,
                                         codedWidth: paddedWidth,
                                         height: index.height)
                Self.replicateLastColumn(plane: &a,
                                         displayWidth: index.width,
                                         codedWidth: paddedWidth,
                                         height: index.height)
            }
            let yRealHeight = index.height / 4 * 4
            if yRealHeight < index.height {
                Self.replicateLastRow(plane: &y,
                                      width: paddedWidth,
                                      realHeight: yRealHeight,
                                      bufferHeight: index.height)
                Self.replicateLastRow(plane: &a,
                                      width: paddedWidth,
                                      realHeight: yRealHeight,
                                      bufferHeight: index.height)
            }
            let chromaRealHeight = result.chromaHeight / 4 * 4
            if chromaRealHeight < result.chromaHeight {
                Self.replicateLastRow(plane: &co,
                                      width: result.chromaWidth,
                                      realHeight: chromaRealHeight,
                                      bufferHeight: result.chromaHeight)
                Self.replicateLastRow(plane: &cg,
                                      width: result.chromaWidth,
                                      realHeight: chromaRealHeight,
                                      bufferHeight: result.chromaHeight)
            }
            hqFrame = DXVRenderer.HQFrameData(
                y: y, co: co, cg: cg, a: a,
                width: index.width, height: index.height,
                codedWidth: paddedWidth, codedHeight: index.height,
                chromaWidth: result.chromaWidth, chromaHeight: result.chromaHeight)
        default:
            throw NSError(domain: "DXVPlayer", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "decodeHQFrame on non-HQ variant"])
        }

        let elapsed = (CACurrentMediaTime() - started) * 1000.0
        recordTiming(elapsed)
        DispatchQueue.main.async { [weak self] in
            self?.onHQFrameDecoded?(frame, hqFrame, elapsed)
        }
    }

    /// Replicate the last real column (index `displayWidth - 1`) into the
    /// padding columns (`displayWidth ..< codedWidth`) of an 8-bit plane.
    ///
    /// Why: the HQ decoder leaves padding bytes at 0. The GL renderer
    /// samples Y / A with GL_LINEAR and applies `uvScaleX = (displayWidth -
    /// 0.5) / codedWidth`, which lands the rightmost output column exactly
    /// on the texel boundary between the last real column and the first
    /// padding column. Linear-blending real-with-0 darkens the rightmost
    /// output column (visible as a 1px dim/blue-tinted rim on non-aligned
    /// clips). Replicating last-real into padding makes the blend a no-op.
    /// Chroma planes don't need this — they sample GL_NEAREST and the right-
    /// edge sample snaps inside the real region.
    private static func replicateLastColumn(
        plane: inout [UInt8],
        displayWidth: Int,
        codedWidth: Int,
        height: Int
    ) {
        precondition(plane.count == codedWidth * height,
                     "replicateLastColumn: plane size mismatch")
        let lastReal = displayWidth - 1
        for row in 0..<height {
            let rowBase = row * codedWidth
            let realValue = plane[rowBase + lastReal]
            for col in displayWidth..<codedWidth {
                plane[rowBase + col] = realValue
            }
        }
    }

    /// Replicate the last real row (`realHeight - 1`) into rows
    /// `realHeight ..< bufferHeight` of an 8-bit plane.
    ///
    /// Why: DXVHQDecoder produces planes by decoding 4x4 blocks. When
    /// the plane's allocated row count isn't a multiple of 4 (in
    /// particular the chroma plane at half-resolution — `chromaHeight =
    /// codedHeight / 2`, which is odd-mod-4 for ~half of real-world
    /// portrait clips), the trailing rows past the last complete
    /// block-row stay at the buffer's initial zero. At v=1.0 the
    /// renderer samples those zero rows (Y via GL_LINEAR clamps to
    /// `bufferHeight-1`; chroma via GL_NEAREST snaps to
    /// `chromaHeight-1`) and produces a 1-2 pixel dim / blue rim along
    /// the bottom edge.
    ///
    /// Discovered diagnosing the bottom-edge blue rim on 908x2276
    /// portrait YCG6 clips: `chromaHeight=1138`, 4-row blocks fit
    /// only 1136 → rows 1136-1137 left at zero.
    private static func replicateLastRow(
        plane: inout [UInt8],
        width: Int,
        realHeight: Int,
        bufferHeight: Int
    ) {
        precondition(plane.count == width * bufferHeight,
                     "replicateLastRow: plane size mismatch")
        guard realHeight < bufferHeight else { return }
        guard realHeight > 0 else { return }
        let lastRealBase = (realHeight - 1) * width
        plane.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for row in realHeight..<bufferHeight {
                base.advanced(by: row * width).update(
                    from: base.advanced(by: lastRealBase),
                    count: width
                )
            }
        }
    }

    // MARK: - Stats

    private func recordTiming(_ ms: Double) {
        // Always on `queue`. Buffer times, then report periodically on main.
        statsTimes.append(ms)
        let now = CACurrentMediaTime()
        let windowElapsed = now - lastStatsReport
        if windowElapsed >= statsReportInterval, !statsTimes.isEmpty {
            let count = statsTimes.count
            let mean = statsTimes.reduce(0, +) / Double(count)
            let mx = statsTimes.max() ?? 0

            // statsDropped is mutated under pendingLock from main, so
            // read + reset under the same lock.
            pendingLock.lock()
            let dropped = statsDropped
            statsDropped = 0
            pendingLock.unlock()

            let stats = Stats(
                frameCount: count,
                meanDecodeMs: mean,
                maxDecodeMs: mx,
                dropped: dropped,
                windowSeconds: windowElapsed)
            statsTimes.removeAll(keepingCapacity: true)
            lastStatsReport = now
            DispatchQueue.main.async { [weak self] in
                self?.onStats?(stats)
            }
        }
    }
}
