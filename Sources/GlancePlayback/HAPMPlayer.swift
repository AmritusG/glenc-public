// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import QuartzCore
import GlanceCore

/// GPU-direct playback engine for **HapM** (HapY scaled-YCoCg color +
/// HapA BC4 alpha, under a 0x0D outer) (Slice 3). Sibling to `HAPQPlayer`
/// (Slice 2) and `HAPDXTPlayer` (Slice 1): same `FrameClock`, lock-based
/// decode dispatch, audio-master wiring, pooled re-pad rings. The
/// difference: each frame decodes BOTH inner sections — the HapY DXT5
/// color plane AND the HapA BC4 alpha plane — and delivers both raw block
/// payloads (re-padded) via `onHapMFrameDecoded` for
/// `DXVRenderer.uploadHapMFrame` + the NEW two-texture composite shader.
///
/// **Purely additive.** This is a NEW file; it does NOT touch `HAPQPlayer`,
/// `HAPDXTPlayer`, `HAPPlayer`, the `DXVRenderer.Variant` enum, or any
/// existing shader. HapM stays GPU-native: both planes upload as compressed
/// textures (DXT5 color, BC4 alpha) and combine in the fragment shader — no
/// CPU RGBA decode.
///
/// The CRITICAL per-plane detail: HapY is DXT5 (16 B/block), HapA is BC4
/// (8 B/block). The two re-pad rings carry that difference so the alpha
/// plane is never sized as if it were 16 B/block (the silent-corruption
/// trap the BC4 probe + Slice-3 brief flagged).
public final class HAPMPlayer: @unchecked Sendable {
    public let url: URL
    public let index: HAPMovieIndex
    public let clock: FrameClock

    private let fileHandle: FileHandle

    /// HapM path: re-padded color (DXT5, 16-px/16-B) + alpha (BC4, 16-px/8-B)
    /// bytes ready for `DXVRenderer.uploadHapMFrame`, plus display dims.
    public var onHapMFrameDecoded: ((_ frameIndex: Int, _ colorDXT5: Data,
                                     _ alphaBC4: Data, _ decodeMs: Double) -> Void)?

    public var onDecodeError: ((_ frameIndex: Int, _ error: Error) -> Void)?
    public var onStats: ((_ stats: Stats) -> Void)?

    // MARK: - Audio (parity with HAPQPlayer / HAPDXTPlayer / DXVPlayer).
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
    private let queue = DispatchQueue(label: "com.amritus.glance.hapmplayer", qos: .userInteractive)

    // MARK: - Lock-based decode dispatch (identical contract to siblings).
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
            String(format: "hap-m: %d frames, decode mean=%.1fms max=%.1fms, dropped=%d (%.1fs window)",
                   frameCount, meanDecodeMs, maxDecodeMs, dropped, windowSeconds)
        }
    }

    // MARK: - Pooled re-pad rings — SEPARATE for color (16 B/block) and
    // alpha (8 B/block). 16-aligned widths pass through with no copy.
    private let colorRing = HapMRepadRing(slotCount: 3)
    private let alphaRing = HapMRepadRing(slotCount: 3)

    public init(url: URL) throws {
        self.url = url
        let idx = try HAPDemuxer.demux(url: url)
        switch idx.variant {
        case .hapM:
            break
        case .hap1, .hap5, .hapY, .hapA:
            throw NSError(domain: "HAPMPlayer", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "HAPMPlayer handles HapM only; \(idx.variant.displayName) is not a Slice-3 variant"])
        }
        guard let firstFrame = idx.frames.first, firstFrame.size > 0 else {
            throw NSError(domain: "HAPMPlayer", code: 2, userInfo: [
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

    // MARK: - Public transport API (matches the sibling players)

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

    // MARK: - Decode pipeline (lock-based, mirrors HAPQPlayer)

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
                throw NSError(domain: "HAPMPlayer", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "frame \(frame) read short"])
            }

            // Walk the 0x0D outer → decode BOTH inner sections (any
            // 0xAF/0xBF/0xCF color + 0xA1/0xB1/0xC1 alpha; Snappy/chunked
            // reassembly happens inside HAPPacketDecoder.decode). Mirrors
            // HAPHQDecoder.decodeHapMToRGBA's inner walk but keeps the raw
            // block payloads for GPU upload instead of compositing on CPU.
            let (color, alpha) = try Self.extractPlanes(from: pkt)

            // Re-pad: color DXT5 at 16 B/block, alpha BC4 at 8 B/block,
            // both to the renderer's 16-pixel width stride.
            let colorDXT5 = repad(color, blockBytes: 16, ring: colorRing)
            let alphaBC4  = repad(alpha, blockBytes: 8,  ring: alphaRing)

            let elapsed = (CACurrentMediaTime() - started) * 1000.0
            recordTiming(elapsed)
            DispatchQueue.main.async { [weak self] in
                self?.onHapMFrameDecoded?(frame, colorDXT5, alphaBC4, elapsed)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onDecodeError?(frame, error)
            }
        }
    }

    /// Walk the 0x0D outer of a HapM packet, decode each inner section,
    /// and return the raw (color DXT5, alpha BC4) block payloads. Throws
    /// if the outer isn't 0x0D or either plane is missing.
    private static func extractPlanes(from pkt: Data) throws -> (color: Data, alpha: Data) {
        let outer = try HAPPacketDecoder.parseSectionHeader(packet: pkt)
        guard outer.sectionType == 0x0D else {
            throw NSError(domain: "HAPMPlayer", code: 4, userInfo: [
                NSLocalizedDescriptionKey: String(format: "HapM expected outer 0x0D, got 0x%02X", outer.sectionType)])
        }
        let iStart = pkt.startIndex + outer.payloadOffset
        let inner = pkt.subdata(in: iStart ..< iStart + outer.payloadLength)
        var color: Data?, alpha: Data?
        var cursor = 0
        while cursor < inner.count {
            let sub = inner.subdata(in: inner.startIndex + cursor ..< inner.endIndex)
            let sh = try HAPPacketDecoder.parseSectionHeader(packet: sub)
            let total = sh.payloadOffset + sh.payloadLength
            let secData = sub.subdata(in: sub.startIndex ..< sub.startIndex + total)
            let (payload, kind) = try HAPPacketDecoder.decode(packet: secData)
            switch kind {
            case .scaledYCoCg: color = payload
            case .rgtc1Alpha:  alpha = payload
            default: break
            }
            cursor += total
        }
        guard let c = color, let a = alpha else {
            throw NSError(domain: "HAPMPlayer", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "HapM frame missing \(color == nil ? "color" : "alpha") inner section"])
        }
        return (c, a)
    }

    /// Re-pad a plane to the renderer's 16-pixel width stride at the given
    /// block size (16 = DXT5 color, 8 = BC4 alpha). Passthrough (no copy)
    /// for 16-aligned widths; otherwise into a pooled ring slot.
    private func repad(_ payload: Data, blockBytes: Int, ring: HapMRepadRing) -> Data {
        let lay = HAPDXTRepad.layout(width: index.width, height: index.height, blockBytes: blockBytes)
        if lay.passthrough { return payload }
        guard payload.count >= lay.srcByteCount else { return payload }
        let slot = ring.slot(byteCount: lay.dstByteCount)
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

/// Round-robin pool of fixed-size raw byte buffers for the HapM re-pad
/// path. Duplicate of the sibling players' file-private rings (not visible
/// across files) — kept separate so those stay untouched per the Slice-3
/// additive constraint. HapM uses TWO instances (color + alpha) because
/// the two planes have different block sizes → different slot sizes.
private final class HapMRepadRing {
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
