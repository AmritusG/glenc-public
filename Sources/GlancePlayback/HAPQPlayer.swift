// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import QuartzCore
import GlanceCore

/// GPU-direct playback engine for **Hap Q (HapY — Scaled YCoCg DXT5)**
/// (Slice 2). Sibling to `HAPDXTPlayer` (Slice 1, Hap1/Hap5) and
/// `DXVPlayer`: same `FrameClock`, same lock-based decode dispatch, same
/// audio-master wiring, same pooled re-pad ring. The ONLY differences
/// from `HAPDXTPlayer` are the variant it accepts (HapY) and the callback
/// it delivers — `onHapQFrameDecoded` hands back the raw DXT5 scaled-
/// YCoCg block bytes (re-padded to the renderer's 16-px stride) for
/// `DXVRenderer.uploadHapQFrame` + the NEW scaled-YCoCg shader, NOT the
/// plain-DXT `onFrameDecoded(...variant...)` of the Slice-1 path.
///
/// **Purely additive.** This type is a NEW file; it does NOT touch
/// `HAPDXTPlayer`, `HAPPlayer`, `DXVPlayer`, the `DXVRenderer.Variant`
/// enum, or the existing DXV3 YCoCg shader. HapY stays GPU-native: the
/// DXT5 blocks are uploaded verbatim as a compressed texture and the
/// per-block scale + YCoCg→RGB happen in the fragment shader (no CPU
/// unpack to planes — that is the whole point vs the DXV3 HQ path).
///
/// HapM / HapA are rejected at init — those multi-section / alpha-only
/// variants have their own players (HAPMPlayer, HAPPlayer).
public final class HAPQPlayer: @unchecked Sendable {
    public let url: URL
    public let index: HAPMovieIndex
    public let clock: FrameClock

    private let fileHandle: FileHandle

    /// Hap Q path: re-padded DXT5 scaled-YCoCg bytes ready for
    /// `DXVRenderer.uploadHapQFrame`, plus display dimensions.
    public var onHapQFrameDecoded: ((_ frameIndex: Int, _ dxt5Bytes: Data,
                                     _ decodeMs: Double) -> Void)?

    public var onDecodeError: ((_ frameIndex: Int, _ error: Error) -> Void)?
    public var onStats: ((_ stats: Stats) -> Void)?

    // MARK: - Audio (parity with HAPDXTPlayer / DXVPlayer). Audio is the
    // canonical clock when present; a missing/failed track never freezes
    // video — it falls back to the wall clock and surfaces `audioState`.
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
    private let queue = DispatchQueue(label: "com.amritus.glance.hapqplayer", qos: .userInteractive)

    // MARK: - Lock-based decode dispatch (identical contract to
    // DXVPlayer / HAPDXTPlayer — only one service block in the GCD queue,
    // always processing the latest pending frame).
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
            String(format: "hap-q: %d frames, decode mean=%.1fms max=%.1fms, dropped=%d (%.1fs window)",
                   frameCount, meanDecodeMs, maxDecodeMs, dropped, windowSeconds)
        }
    }

    // MARK: - Pooled re-pad ring (zero per-frame allocation for the
    // non-16-aligned-width path; 16-aligned widths pass through with no
    // copy). HapY is always DXT5 → 16 bytes/block.
    private let repadRing = HapQRepadRing(slotCount: 3)

    public init(url: URL) throws {
        self.url = url
        let idx = try HAPDemuxer.demux(url: url)
        switch idx.variant {
        case .hapY:
            break
        case .hap1, .hap5, .hapM, .hapA:
            throw NSError(domain: "HAPQPlayer", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "HAPQPlayer handles Hap Q (HapY) only; \(idx.variant.displayName) is not a Slice-2 variant"])
        }
        guard let firstFrame = idx.frames.first, firstFrame.size > 0 else {
            throw NSError(domain: "HAPQPlayer", code: 2, userInfo: [
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

        // Audio-master setup, mirroring HAPDXTPlayer / DXVPlayer exactly.
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

    // MARK: - Public transport API (matches HAPDXTPlayer / DXVPlayer)

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

    // MARK: - Decode pipeline (lock-based, mirrors HAPDXTPlayer)

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
            try fileHandle.seek(toOffset: entry.fileOffset)
            guard let pkt = try fileHandle.read(upToCount: Int(entry.size)),
                  pkt.count == Int(entry.size) else {
                throw NSError(domain: "HAPQPlayer", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "frame \(frame) read short"])
            }

            // Section-header parse + Snappy + chunked (0xAF/0xBF/0xCF)
            // reassembly all happen inside decode(); we get raw DXT5
            // scaled-YCoCg blocks back. Anything but scaledYCoCg here
            // means a mislabelled container.
            let (payload, kind) = try HAPPacketDecoder.decode(packet: pkt)
            guard kind == .scaledYCoCg else {
                throw NSError(domain: "HAPQPlayer", code: 4, userInfo: [
                    NSLocalizedDescriptionKey:
                        "frame \(frame): expected scaledYCoCg, got \(kind)"])
            }

            // Re-pad the DXT5 blocks from HAP's 4-px block alignment into
            // the renderer's 16-px stride — exactly the bytes
            // uploadHapQFrame samples (same path as Slice 1 Hap5).
            let dxt5Bytes = repadToRendererLayout(payload)
            let elapsed = (CACurrentMediaTime() - started) * 1000.0
            recordTiming(elapsed)
            DispatchQueue.main.async { [weak self] in
                self?.onHapQFrameDecoded?(frame, dxt5Bytes, elapsed)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onDecodeError?(frame, error)
            }
        }
    }

    /// Transform HAP's 4-px-block-aligned DXT5 rows into the renderer's
    /// 16-px-aligned stride (zero-filled pad blocks the renderer crops at
    /// draw time). Fast path: 16-aligned width → pass through, no copy.
    /// Otherwise re-pad into a pooled ring slot (no per-frame allocation).
    private func repadToRendererLayout(_ payload: Data) -> Data {
        let lay = HAPDXTRepad.layout(width: index.width, height: index.height,
                                     blockBytes: 16)  // HapY is always DXT5
        if lay.passthrough { return payload }
        guard payload.count >= lay.srcByteCount else { return payload }
        let slot = repadRing.slot(byteCount: lay.dstByteCount)  // zero-init pad
        HAPDXTRepad.fill(into: slot, payload: payload, layout: lay)
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

/// Round-robin pool of fixed-size raw byte buffers for the Hap Q re-pad
/// path. Duplicate of `HAPDXTPlayer`'s file-private `RepadRing` (which is
/// not visible across files) — kept separate so HAPDXTPlayer.swift stays
/// untouched per the Slice-2 additive constraint. Same contract: realloc
/// only on size change, zero-init slots, round-robin hand-out N deep so a
/// deferred upload reads a slot the decode loop won't overwrite first.
private final class HapQRepadRing {
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
