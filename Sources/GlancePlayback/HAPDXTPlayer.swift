// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import QuartzCore
import GlanceCore

/// GPU-direct playback engine for the DXT-block HAP variants — **Hap1
/// (RGB DXT1)** and **Hap5 (RGBA DXT5)** (Slice 1). Sibling to
/// `DXVPlayer`: same `FrameClock` clock, same lock-based decode
/// dispatch, same `onFrameDecoded` shape — but instead of LZF-
/// decompressing a DXV3/DXV1 packet it runs `HAPPacketDecoder.decode`
/// (which handles the section header + Snappy + chunked reassembly)
/// and re-pads the resulting DXT block rows from HAP's 4-pixel block
/// alignment into the 16-pixel-aligned layout `DXVRenderer.uploadFrame`
/// expects. The decoded blocks are then GPU-sampled by the *existing,
/// unmodified* `DXVRenderer` DXT path (it replaced the former mpv CPU
/// decode for these two variants).
///
/// **Purely additive.** This type does NOT touch `DXVRenderer`, the
/// `DXVRenderer.Variant` enum, `DXVPlayer`, or `HAPPlayer` (the CPU-
/// RGBA thumbnail/HAP-Q engine, which stays as-is for the variants
/// this slice does not cover; HapY / HapM have their own GPU players, HapA
/// plays through `HAPPlayer`).
///
/// HapY / HapM / HapA are rejected at init — callers must gate on
/// `HAPMovieIndex.variant ∈ {.hap1, .hap5}` before constructing this.
///
/// Usage mirrors DXVPlayer:
/// ```
///   let player = try HAPDXTPlayer(url: url)
///   player.onFrameDecoded = { idx, dxtBytes, variant, decodeMs in ... }
///   player.play()
/// ```
public final class HAPDXTPlayer: @unchecked Sendable {
    public let url: URL
    public let index: HAPMovieIndex
    public let clock: FrameClock

    private let fileHandle: FileHandle

    /// DXT path: padded DXT bytes ready for `DXVRenderer.uploadFrame`.
    /// `variant` is resolved per-frame from the packet's `TextureKind`
    /// (`.dxt1Rgb → .dxt1`, `.dxt5Rgba → .dxt5`) — authoritative per
    /// frame, never assumed from the demuxer's container variant.
    public var onFrameDecoded: ((_ frameIndex: Int, _ dxtBytes: Data,
                                 _ variant: DXVRenderer.Variant,
                                 _ decodeMs: Double) -> Void)?

    public var onDecodeError: ((_ frameIndex: Int, _ error: Error) -> Void)?
    public var onStats: ((_ stats: Stats) -> Void)?

    // MARK: - Audio (parity with DXVPlayer so HAP-with-audio does not
    // regress vs the former mpv path). Audio is the canonical
    // clock when present; video follows via `clock.audioTimeSource`.
    // A missing/failed audio track NEVER fails playback and is NEVER a
    // silent freeze — video continues on the wall-clock master and the
    // outcome is surfaced as `audioState`. Reuses `DXVPlayer.AudioState`
    // so `PlayerModel`'s audio facade maps both engines identically.
    public private(set) var audioState: DXVPlayer.AudioState = .none(reason: "uninitialized")
    public var onAudioStateChange: ((DXVPlayer.AudioState) -> Void)?
    public private(set) var audioLengthMismatch: Bool = false

    public var volume: Float {
        get { audioClock?.volume ?? 1.0 }
        set { audioClock?.volume = newValue }
    }
    public var isMuted: Bool {
        get { audioClock?.isMuted ?? false }
        set { audioClock?.isMuted = newValue }
    }

    private var audioClock: AudioClock?
    private let queue = DispatchQueue(label: "com.amritus.glance.hapdxtplayer", qos: .userInteractive)

    // MARK: - Lock-based decode dispatch (identical contract to
    // DXVPlayer.requestDecode/servicePending — see that file for the
    // rationale; the short version is: only ever one service block in
    // the GCD queue, always processing the latest pending frame, so
    // scrub-and-hold latency stays at one decode cycle).
    private let pendingLock = NSLock()
    private var pendingFrame: Int? = nil
    private var serviceScheduled = false
    private var inFlight = false

    // MARK: - Stats
    private var statsTimes: [Double] = []
    private var statsDropped: Int = 0
    private var lastStatsReport: CFTimeInterval = CACurrentMediaTime()
    private let statsReportInterval: CFTimeInterval = 1.0

    public var enableDiagnostics: Bool = false

    public struct Stats {
        public let frameCount: Int
        public let meanDecodeMs: Double
        public let maxDecodeMs: Double
        public let dropped: Int
        public let windowSeconds: Double
        public var summary: String {
            String(format: "hap-dxt: %d frames, decode mean=%.1fms max=%.1fms, dropped=%d (%.1fs window)",
                   frameCount, meanDecodeMs, maxDecodeMs, dropped, windowSeconds)
        }
    }

    // MARK: - Pooled re-pad ring (zero per-frame allocation during
    // playback for the non-16-aligned-width path). For 16-aligned
    // widths the HAP payload is already in the layout the renderer
    // wants, so it is passed through with no re-pad and the ring is
    // never touched. The ring owns its buffers for the player's whole
    // lifetime; each re-padded frame is wrapped as a no-copy `Data`
    // pointing at a slot, and slots are reused round-robin — N deep so
    // the deferred upload (which runs on the next draw) reads a slot
    // the decode loop will not overwrite before then.
    private let repadRing = RepadRing(slotCount: 3)

    public init(url: URL) throws {
        self.url = url
        let idx = try HAPDemuxer.demux(url: url)
        // Slice 1 covers the two DXT-block variants only. The HapQ
        // family (scaled-YCoCg / RGTC1 alpha / multi-texture) needs a
        // new shader and is explicitly out of scope — reject so the
        // caller routes those to their own players.
        switch idx.variant {
        case .hap1, .hap5:
            break
        case .hapY, .hapM, .hapA:
            throw NSError(domain: "HAPDXTPlayer", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "HAPDXTPlayer handles Hap1/Hap5 only; \(idx.variant.displayName) is not a Slice-1 variant"])
        }
        guard let firstFrame = idx.frames.first, firstFrame.size > 0 else {
            throw NSError(domain: "HAPDXTPlayer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "no frames in file"])
        }
        self.index = idx
        self.fileHandle = try FileHandle(forReadingFrom: url)
        self.clock = FrameClock(
            frameRate: idx.frameRate > 0 ? idx.frameRate : 30.0,
            totalFrames: idx.frames.count)
        self.clock.onFrameChange = { [weak self] frameIdx in
            self?.requestDecode(frame: frameIdx)
        }

        // Audio-master setup, mirroring DXVPlayer exactly. AudioClock is
        // container-generic (it reads the first audio track via
        // AVFoundation), so it works for HAP MOVs the same as DXV MOVs.
        do {
            let ac = try AudioClock(url: url, loops: clock.loops)
            self.audioClock = ac
            self.audioState = .playing(sampleRate: ac.sampleRate, channels: ac.channelCount)
            let videoDuration = Double(idx.frames.count) / clock.frameRate
            self.audioLengthMismatch = abs(ac.durationSeconds - videoDuration) > (1.0 / clock.frameRate)
            self.clock.audioTimeSource = { [weak ac] in ac?.currentSeconds() }
            self.clock.onSeek = { [weak self] frame in
                guard let self = self else { return }
                self.audioClock?.seek(toSeconds: Double(frame) / self.clock.frameRate)
            }
            self.clock.onAudioUnavailable = { [weak self] in
                self?.fallBackToWallClock(reason: "audio failed to start")
            }
        } catch AudioClockError.noAudioTrack {
            self.audioClock = nil
            self.audioState = .none(reason: "no audio track")
        } catch {
            self.audioClock = nil
            self.audioState = .failed(reason: Self.audioFailureReason(error))
        }
    }

    private static func audioFailureReason(_ error: Error) -> String {
        if let e = error as? AudioClockError { return e.description }
        return error.localizedDescription
    }

    private func setAudioState(_ newState: DXVPlayer.AudioState) {
        audioState = newState
        onAudioStateChange?(newState)
    }

    /// Runtime audio failure must NOT silently freeze video — revert to
    /// the wall clock, tear down the dead engine, re-anchor to the
    /// current frame, and surface the degraded state. Mirrors
    /// DXVPlayer.fallBackToWallClock. Main-thread only.
    private func fallBackToWallClock(reason: String) {
        guard audioClock != nil else { return }
        audioClock?.stop()
        audioClock = nil
        clock.audioTimeSource = nil
        clock.onSeek = nil
        clock.onAudioUnavailable = nil
        clock.seek(to: clock.currentFrame)
        setAudioState(.failed(reason: reason))
    }

    deinit {
        clock.stop()
        audioClock?.stop()
        try? fileHandle.close()
    }

    // MARK: - Public transport API (matches DXVPlayer)

    public func play() {
        clock.start()
        let audioStarted = audioClock?.play() ?? true
        clock.play()
        if audioClock != nil && !audioStarted {
            fallBackToWallClock(reason: "audio engine failed to start")
        }
    }

    public func pause() {
        clock.pause()
        audioClock?.pause()
    }

    public func togglePause() {
        if clock.isPaused { play() } else { pause() }
    }

    public func seek(to frame: Int) {
        clock.seek(to: frame)
    }

    public func stepFrame(forward: Bool) {
        pause()
        let target = max(0, min(totalFrames - 1, currentFrame + (forward ? 1 : -1)))
        seek(to: target)
    }

    public func setLoops(_ on: Bool) {
        clock.loops = on
        audioClock?.setLoops(on)
    }

    public func stop() {
        clock.stop()
        audioClock?.stop()
    }

    public var isPaused: Bool { clock.isPaused }
    public var currentFrame: Int { clock.currentFrame }
    public var totalFrames: Int { index.frames.count }
    public var frameRate: Double { index.frameRate }
    public func currentAudioSeconds() -> Double? { audioClock?.currentSeconds() }

    // MARK: - Decode pipeline (lock-based, mirrors DXVPlayer)

    private func requestDecode(frame: Int) {
        pendingLock.lock()
        if pendingFrame != nil {
            statsDropped += 1
        }
        pendingFrame = frame
        let needSchedule = !serviceScheduled
        if needSchedule { serviceScheduled = true }
        pendingLock.unlock()

        if needSchedule {
            queue.async { [weak self] in self?.servicePending() }
        }
    }

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
        guard frame >= 0 && frame < index.frames.count else { return }
        let entry = index.frames[frame]
        let started = CACurrentMediaTime()
        do {
            // D4: reuse the raw-packet READ pattern only — fileOffset +
            // size cover the whole HAP frame packet (section header +
            // payload).
            try fileHandle.seek(toOffset: entry.fileOffset)
            guard let pkt = try fileHandle.read(upToCount: Int(entry.size)),
                  pkt.count == Int(entry.size) else {
                throw NSError(domain: "HAPDXTPlayer", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "frame \(frame) read short"])
            }

            // D3: section-header parse + Snappy + chunked reassembly all
            // happen inside decode(); we get raw DXT blocks back. Slice 1
            // only accepts the two DXT-block kinds; anything else means a
            // mislabelled container and is surfaced as a decode error.
            let (payload, kind) = try HAPPacketDecoder.decode(packet: pkt)
            let variant: DXVRenderer.Variant
            let blockBytes: Int
            switch kind {
            case .dxt1Rgb:  variant = .dxt1; blockBytes = 8
            case .dxt5Rgba: variant = .dxt5; blockBytes = 16
            case .scaledYCoCg, .rgtc1Alpha:
                throw NSError(domain: "HAPDXTPlayer", code: 4, userInfo: [
                    NSLocalizedDescriptionKey:
                        "frame \(frame): non-DXT TextureKind \(kind) not handled by Slice 1"])
            }

            let dxtBytes = repadToRendererLayout(payload, blockBytes: blockBytes)
            let elapsed = (CACurrentMediaTime() - started) * 1000.0
            recordTiming(elapsed)
            DispatchQueue.main.async { [weak self] in
                self?.onFrameDecoded?(frame, dxtBytes, variant, elapsed)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onDecodeError?(frame, error)
            }
        }
    }

    /// Transform HAP's 4-pixel-block-aligned DXT rows into the
    /// 16-pixel-aligned (`paddedWidth = (w+15)/16*16`) row stride
    /// `DXVRenderer.uploadCompressed` expects, zero-filling the pad
    /// blocks at the right of each block row. The renderer crops those
    /// pad columns back off at draw time via its per-frame UV scale, so
    /// they are never visible.
    ///
    /// Fast path: when `width` is already a multiple of 16 the HAP and
    /// renderer layouts are byte-identical, so the payload is returned
    /// as-is (no copy, no ring slot).
    ///
    /// Otherwise the re-padded frame is written into a pooled ring slot
    /// (no per-frame heap allocation) and returned as a no-copy `Data`
    /// view onto that slot.
    private func repadToRendererLayout(_ payload: Data, blockBytes: Int) -> Data {
        let lay = HAPDXTRepad.layout(width: index.width, height: index.height,
                                     blockBytes: blockBytes)

        // 16-aligned width → identical layout, pass through (no copy).
        if lay.passthrough {
            return payload
        }

        // Guard against a short/odd payload (mislabelled alignment):
        // fall back to the un-repadded payload rather than reading OOB.
        // uploadCompressed will reject a wrong-sized buffer cleanly.
        guard payload.count >= lay.srcByteCount else {
            return payload
        }

        let slot = repadRing.slot(byteCount: lay.dstByteCount)  // zero-init; pad bytes stay 0
        HAPDXTRepad.fill(into: slot, payload: payload, layout: lay)
        // No-copy view onto the ring slot. The ring owns the storage
        // (freed in its deinit, which outlives any in-flight upload
        // because the player owns the ring); `.none` deallocator means
        // releasing this Data does not touch the buffer.
        return Data(bytesNoCopy: slot.baseAddress!, count: lay.dstByteCount, deallocator: .none)
    }

    private func recordTiming(_ ms: Double) {
        statsTimes.append(ms)
        let now = CACurrentMediaTime()
        let window = now - lastStatsReport
        guard window >= statsReportInterval, !statsTimes.isEmpty else { return }
        let mean = statsTimes.reduce(0, +) / Double(statsTimes.count)
        let maxv = statsTimes.max() ?? 0
        let stats = Stats(frameCount: statsTimes.count, meanDecodeMs: mean,
                          maxDecodeMs: maxv, dropped: statsDropped, windowSeconds: window)
        statsTimes.removeAll(keepingCapacity: true)
        statsDropped = 0
        lastStatsReport = now
        DispatchQueue.main.async { [weak self] in self?.onStats?(stats) }
    }
}

/// Round-robin pool of fixed-size raw byte buffers for the re-pad path.
/// Reallocates only when the requested size changes (i.e. on a
/// dimension/variant change between clips), so steady-state playback
/// does zero per-frame allocation. All slots are zero-initialised on
/// (re)allocation and the re-pad only ever overwrites the data columns,
/// so the pad columns stay zero across reuses. Slots are handed out
/// round-robin and `slotCount` is deep enough that the deferred upload
/// of one frame reads a slot the decode loop will not overwrite before
/// the draw consumes it.
private final class RepadRing {
    private var slots: [UnsafeMutableRawBufferPointer] = []
    private var capacity = 0
    private var next = 0
    private let slotCount: Int

    init(slotCount: Int) { self.slotCount = max(2, slotCount) }

    func slot(byteCount: Int) -> UnsafeMutableRawBufferPointer {
        if capacity != byteCount {
            for s in slots { s.deallocate() }
            slots = (0..<slotCount).map { _ -> UnsafeMutableRawBufferPointer in
                let b = UnsafeMutableRawBufferPointer.allocate(
                    byteCount: max(1, byteCount), alignment: 16)
                if let base = b.baseAddress { memset(base, 0, max(1, byteCount)) }
                return b
            }
            capacity = byteCount
            next = 0
        }
        let s = slots[next]
        next = (next + 1) % slotCount
        return s
    }

    deinit { for s in slots { s.deallocate() } }
}
#endif
