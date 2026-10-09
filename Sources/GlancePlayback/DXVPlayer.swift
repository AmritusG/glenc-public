// SPDX-License-Identifier: MIT
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
public final class DXVPlayer: @unchecked Sendable {
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
    public var onHQFrameDecoded: ((_ frameIndex: Int, _ frame: DXVHQFrame, _ decodeMs: Double) -> Void)?

    /// Called on main thread when decode fails for a frame. Player keeps
    /// running on the next frame; this is for logging.
    public var onDecodeError: ((_ frameIndex: Int, _ error: Error) -> Void)?

    /// Called on main thread periodically with running performance
    /// stats. Receives (decoded frames in window, mean decode ms,
    /// max decode ms, dropped frames). Use for the diagnostic gate.
    public var onStats: ((_ stats: Stats) -> Void)?

    /// Stage A audio state. Model data the consumer reads and surfaces in
    /// the UI (§5) — NOT a log line. Set once in `init` and kept accurate:
    /// `.playing` when the clip's audio track loaded and drives the clock,
    /// `.none` when the clip has no audio track (video plays on the
    /// wall-clock master — never a silent drop, §1), `.failed` when an
    /// audio track exists but setup/validation failed (video still plays).
    public enum AudioState: Equatable {
        case playing(sampleRate: Double, channels: Int)
        case none(reason: String)
        case failed(reason: String)
    }

    /// Current audio state (§5). Read by the app to show a "no audio"
    /// indicator. `.none`/`.failed` mean video is on the wall-clock master.
    public private(set) var audioState: AudioState = .none(reason: "uninitialized")

    /// Item 1 §5: fired on the main thread whenever `audioState` changes at
    /// runtime — e.g. a play-time or never-prime fallback to the wall clock
    /// — so the consumer can update its visible indicator. NOT fired for the
    /// initial init-time state (read `audioState` directly after init).
    public var onAudioStateChange: ((AudioState) -> Void)?

    /// Item 2 §5: true when the audio track and video durations differ by
    /// more than one frame, so the consumer can surface the mismatch. Set in
    /// init (both lengths are known once the AudioClock is built).
    public private(set) var audioLengthMismatch: Bool = false

    /// Stage D: audio output gain, LINEAR, clamped to [0, 1]. Default 1.0.
    /// Stored as intent and forwarded to the AudioClock when present (a
    /// harmless no-op on a no-audio player; the getter returns the stored
    /// intent). GAIN ONLY — setting level/mute never stops, reschedules, or
    /// re-anchors the audio node, and never moves the master-clock position:
    /// a muted clip stays in perfect video sync, silent not stopped.
    public var volume: Float {
        get { _volume }
        set {
            _volume = min(1.0, max(0.0, newValue))
            audioClock?.volume = _volume
        }
    }
    /// Mute toggle, SEPARATE from `volume` so unmute restores the prior
    /// level. Default false. Effective node gain = `isMuted ? 0 : volume`.
    public var isMuted: Bool {
        get { _isMuted }
        set {
            _isMuted = newValue
            audioClock?.isMuted = _isMuted
        }
    }
    private var _volume: Float = 1.0
    private var _isMuted: Bool = false

    /// Phase 3d-perf-fix: opt-in frame-prefetch + parallel decompress
    /// pipeline. When `true`, the FrameClock tick consumes ready frames
    /// from a ring buffer instead of triggering a synchronous decode on
    /// the tick. A background task decodes ahead of the display
    /// position; multiple frames decompress concurrently across cores.
    /// **Default `false` so the Mac OpenGL playback path (Crate-Mac,
    /// Glance app, GlEnc, CueGlance) is byte-identically unchanged.**
    /// Crate-iPad sets this to `true` to fix the 4K-clip choppiness
    /// (decode 80–92 ms / frame on iPad M4 vs the 33 ms budget at 30
    /// fps — confirmed by the Phase 3d-perf-diag device run).
    public var prefetchEnabled: Bool = false

    /// Phase 3d-perf-fix: ring-buffer depth when `prefetchEnabled`.
    /// Means the decoder targets staying N frames ahead of display.
    /// Larger = more decode latency hidden but more memory + larger
    /// post-seek refill stall; default 4 fits the typical iPad M4
    /// per-frame decode budget (~30–90 ms) while keeping per-decode
    /// stalls invisible at 30 fps. Tune up if underruns persist.
    public var prefetchAheadFrames: Int = 4

    /// Phase 3d-perf-fix: when true, the prefetch path prints one log
    /// line per tick noting ring HIT / MISS and the underrun count.
    /// Off by default. Crate-iPad's perf-diag flag flips this on for
    /// device measurement runs.
    public var enableDiagnostics: Bool = false

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
    /// Stage A audio engine (audio-master clock). nil when the clip has
    /// no audio track or audio setup failed — video then runs on the
    /// FrameClock wall clock unchanged. Touched only from main.
    private var audioClock: AudioClock?
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

        // Stage A: attempt audio-master setup. Audio is the canonical
        // clock; video follows it via `clock.audioTimeSource` (the single
        // attach point). NEVER silent-drop (§1): a missing or failed audio
        // track does NOT fail playback and is NOT treated as success — the
        // video continues on the wall-clock master and the outcome is
        // recorded as visible `audioState` (§5). The video decode/upload
        // byte path is untouched; audio is purely additive.
        do {
            let ac = try AudioClock(url: url, loops: clock.loops)
            self.audioClock = ac
            self.audioState = .playing(sampleRate: ac.sampleRate, channels: ac.channelCount)
            // Item 2 §5: flag an audio/video length mismatch (> 1 frame) so
            // the consumer can surface it. The clock follows the audio loop
            // length either way (see FrameClock.audioMasterTarget).
            let videoDuration = Double(index.frames.count) / clock.frameRate
            self.audioLengthMismatch = abs(ac.durationSeconds - videoDuration) > (1.0 / clock.frameRate)
            // Replace the clock's time source with the audio render
            // position. Weak so the player→clock→player retain triangle
            // doesn't leak (clock is owned by the player; the audio clock
            // is owned by the player too).
            self.clock.audioTimeSource = { [weak ac] in ac?.currentSeconds() }
            // Keep audio locked to video on every seek (and frame-step,
            // which routes through seek).
            self.clock.onSeek = { [weak self] frame in
                guard let self = self else { return }
                self.audioClock?.seek(toSeconds: Double(frame) / self.clock.frameRate)
            }
            // Item 1: never-prime watchdog — if audio never renders after
            // play, fall back to the wall clock (no silent freeze).
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

    /// Short, human-readable reason for the degraded-audio model state.
    private static func audioFailureReason(_ error: Error) -> String {
        if let e = error as? AudioClockError { return e.description }
        return error.localizedDescription
    }

    /// Update `audioState` and notify observers (Item 1 §5). Use for runtime
    /// transitions; init sets `audioState` directly (no observer wired yet).
    private func setAudioState(_ newState: AudioState) {
        audioState = newState
        onAudioStateChange?(newState)
    }

    /// Item 1 §1/§5: a runtime audio failure must NOT silently freeze video.
    /// Revert the clock to the wall-clock master, tear down the dead engine,
    /// re-anchor to the current frame (no backward jump), and surface the
    /// degraded state. Idempotent — a no-op once audio is already gone.
    /// Main-thread only (called from play() and the FrameClock tick).
    private func fallBackToWallClock(reason: String) {
        guard audioClock != nil else { return }
        audioClock?.stop()
        audioClock = nil
        // Revert to the wall clock and detach the audio hooks.
        clock.audioTimeSource = nil
        clock.onSeek = nil
        clock.onAudioUnavailable = nil
        // Re-anchor the wall clock to the current frame so video continues
        // from where audio left it rather than jumping. (onSeek is already
        // nil, so this does not try to reposition the now-gone audio.)
        clock.seek(to: clock.currentFrame)
        setAudioState(.failed(reason: reason))
    }

    deinit {
        clock.stop()
        // §4: explicit audio teardown. deinit does not auto-cancel the
        // prefetch Task today, and likewise must not rely on stop() having
        // been called — tear the audio engine down here directly.
        audioClock?.stop()
        try? fileHandle.close()
    }

    // MARK: - Public API

    public func play() {
        print("Glance/player: play() called")
        clock.start()  // safe to call repeatedly
        // Start audio; if the engine reports it could not start (Item 1),
        // fall back to the wall clock so video never freezes on a clock
        // that will never advance. `?? true` means "no audio clock → OK".
        let audioStarted = audioClock?.play() ?? true
        clock.play()
        if audioClock != nil && !audioStarted {
            fallBackToWallClock(reason: "audio engine failed to start")
        }
        if prefetchEnabled {
            startPrefetch()
        }
    }

    public func pause() {
        clock.pause()
        audioClock?.pause()
    }

    public func togglePause() {
        // Route through play()/pause() so audio follows the same path.
        if clock.isPaused { play() } else { pause() }
    }

    public func seek(to frame: Int) {
        // Audio is repositioned via clock.onSeek (wired in init) so seek
        // and frame-step share one path; nothing to do here for audio.
        clock.seek(to: frame)
    }

    /// Step one frame, holding audio paused. A bare `clock.stepFrame` pauses
    /// only the video clock, so the follow-on seek hits `AudioClock.seek`'s
    /// isPlaying branch and resumes audio. Pausing the player first (audio +
    /// clock) makes the seek re-anchor audio held. Use this, not
    /// `clock.stepFrame`.
    public func stepFrame(forward: Bool) {
        pause()
        let target = max(0, min(totalFrames - 1, currentFrame + (forward ? 1 : -1)))
        seek(to: target)
    }

    /// Set loop state on both the video clock and (in lockstep) the audio
    /// engine, so audio loops/holds with the video. Use this instead of
    /// mutating `clock.loops` directly when an audio track is present.
    public func setLoops(_ on: Bool) {
        clock.loops = on
        audioClock?.setLoops(on)
    }

    public func stop() {
        clock.stop()
        audioClock?.stop()
        stopPrefetch()
    }

    public var isPaused: Bool { clock.isPaused }
    public var currentFrame: Int { clock.currentFrame }
    public var totalFrames: Int { index.frames.count }
    public var frameRate: Double { index.frameRate }

    /// Sample-accurate playback position in seconds, read straight from
    /// the audio master clock. Returns nil when the file has no audio
    /// track or audio has not primed yet (no valid render time) — the
    /// caller should hold the frame-derived time in that case. Pure
    /// forwarder: does not touch AudioClock or FrameClock scheduling.
    public func currentAudioSeconds() -> Double? { audioClock?.currentSeconds() }

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
        // Phase 3d-perf-fix: opt-in prefetch route. When enabled, the
        // tick consumes a ready frame from the ring instead of
        // triggering a fresh decode. Mac consumers keep the old path
        // (prefetchEnabled defaults to false).
        if prefetchEnabled {
            consumeFromPrefetchRing(frame: frame)
            return
        }
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
            let kind = try Self.decodeKind(packet: pkt, decoder: queueDecoder)
            let elapsed = (CACurrentMediaTime() - started) * 1000.0
            recordTiming(elapsed)
            DispatchQueue.main.async { [weak self] in
                switch kind {
                case .dxt(let data): self?.onFrameDecoded?(frame, data, elapsed)
                case .hq(let hq): self?.onHQFrameDecoded?(frame, hq, elapsed)
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onDecodeError?(frame, error)
            }
        }
    }

    /// The serial decode queue's decoder: DXVKit buffers reused frame to
    /// frame. Only touched on `queue`.
    private lazy var queueDecoder = DXVFrameDecoder(index: index)

    /// Packet → GPU-ready frame, decoded by DXVKit (via GlanceCore's
    /// `DXVFrameDecoder`): DXT1 / DXT5 → BC1 / BC3 bytes with 16-pixel
    /// aligned block columns and ceil(height / 4) block rows;
    /// YCG6 / YG10 → BC4 / BC5 block streams over the 16 x 16 padded coded
    /// texture (`DXVHQFrame`), uploaded as compressed textures. Pure over
    /// its inputs: the prefetch path gives each concurrent task its own
    /// decoder.
    private static func decodeKind(packet: Data, decoder: DXVFrameDecoder) throws -> DecodedFrameKind {
        switch try decoder.decode(packet: packet) {
        case .dxt(let data):
            return .dxt(data)
        case .hq(let b):
            return .hq(DXVHQFrame(lumaBlocks: b.luma, chromaBlocks: b.chroma, hasAlpha: b.hasAlpha,
                                  width: decoder.index.width, height: decoder.index.height,
                                  codedWidth: b.codedWidth, codedHeight: b.codedHeight))
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

    // MARK: - Phase 3d-perf-fix: frame-prefetch + parallel decompress

    /// One decoded frame held in the prefetch ring. Either DXT-shape
    /// (compressed BC bytes) or HQ-shape (four planes), matching the
    /// callback the consumer ultimately receives.
    private enum DecodedFrameKind: Sendable {
        case dxt(Data)
        case hq(DXVHQFrame)
    }

    private struct DecodedFrameEntry: Sendable {
        let frameIdx: Int
        let kind: DecodedFrameKind
        let decodeMs: Double
    }

    /// Actor wrapping the ring + inflight set + display position.
    /// All cross-thread access to prefetch state goes through here.
    private actor PrefetchState {
        private(set) var displayFrame: Int = 0
        private var ring: [Int: DecodedFrameEntry] = [:]
        private var inflight: Set<Int> = []

        func setDisplayFrame(_ f: Int) { displayFrame = f }

        /// Snapshot for the loop's window-computation step. Pure read.
        func snapshot() -> (display: Int, ring: Set<Int>, inflight: Set<Int>) {
            (displayFrame, Set(ring.keys), inflight)
        }

        /// Reserve a frame slot; returns true if we should kick a task.
        /// False if the frame is already in the ring or already
        /// decoding.
        func reserve(_ f: Int) -> Bool {
            if ring[f] != nil { return false }
            if inflight.contains(f) { return false }
            inflight.insert(f)
            return true
        }

        func cancelReservation(_ f: Int) { inflight.remove(f) }

        func deposit(_ entry: DecodedFrameEntry) {
            inflight.remove(entry.frameIdx)
            ring[entry.frameIdx] = entry
        }

        /// Withdraw the frame requested by the display tick. Removes
        /// from the ring (consumer takes ownership). Returns nil on
        /// miss (underrun: decoder couldn't keep up).
        func withdraw(_ f: Int) -> DecodedFrameEntry? {
            return ring.removeValue(forKey: f)
        }

        /// Drop entries whose frame index is older than `f`. Called
        /// from the display-tick consumer to free RAM. Handles loop
        /// wraparound by NOT evicting indices within a small forward
        /// window: only strictly-less is evicted (forward indices stay).
        func evictOlderThan(_ f: Int) {
            ring = ring.filter { $0.key >= f }
        }

        /// Drop everything. Used post-seek when the new display
        /// position is far from where we were prefetching.
        func flush() {
            ring.removeAll()
        }
    }

    private let prefetchState = PrefetchState()
    private var prefetchTask: Task<Void, Never>?
    private var prefetchUnderruns: Int = 0
    private var prefetchHits: Int = 0
    private var lastDeliveredFrame: Int = -1

    private func startPrefetch() {
        guard prefetchEnabled, prefetchTask == nil else { return }
        let total = index.frames.count
        let ahead = max(1, prefetchAheadFrames)
        prefetchTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.prefetchLoop(total: total, ahead: ahead)
        }
    }

    private func stopPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        Task { [state = prefetchState] in await state.flush() }
    }

    /// Display-tick consumer. Withdraws a ready frame from the ring
    /// (cheap if hit; near-zero work) and delivers it through the
    /// usual `onFrameDecoded` / `onHQFrameDecoded` callbacks. On miss
    /// (the decoder hasn't produced this frame yet) logs an underrun
    /// and holds the previous frame on screen — no callback fires.
    /// All instance-state mutation runs on the MainActor — the actor
    /// snapshot/withdraw/evict steps run inside a single Task so
    /// they're ordered relative to one another but reach the actor
    /// concurrently with the worker's deposit operations (actor
    /// serializes them).
    private func consumeFromPrefetchRing(frame: Int) {
        Task { [weak self, state = prefetchState] in
            await state.setDisplayFrame(frame)
            let entry = await state.withdraw(frame)
            if entry != nil {
                await state.evictOlderThan(frame)
            }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                if let entry {
                    self.prefetchHits += 1
                    self.lastDeliveredFrame = frame
                    if self.enableDiagnostics {
                        print(String(format: "Glance/player/prefetch: HIT frame=%d decodeMs=%.2f",
                                     frame, entry.decodeMs))
                    }
                    // recordTiming runs on the decoder queue (its
                    // thread-safety invariant) — hop there.
                    let ms = entry.decodeMs
                    self.queue.async { [weak self] in
                        self?.recordTiming(ms)
                    }
                    switch entry.kind {
                    case .dxt(let data):
                        self.onFrameDecoded?(entry.frameIdx, data, entry.decodeMs)
                    case .hq(let hq):
                        self.onHQFrameDecoded?(entry.frameIdx, hq, entry.decodeMs)
                    }
                } else {
                    self.prefetchUnderruns += 1
                    // Treat as dropped for the existing onStats counter
                    // so consumer-facing diagnostics still surface the
                    // shortfall.
                    self.pendingLock.lock()
                    self.statsDropped += 1
                    self.pendingLock.unlock()
                    if self.enableDiagnostics {
                        print("Glance/player/prefetch: MISS frame=\(frame) underruns=\(self.prefetchUnderruns) (decoder behind — holding last)")
                    }
                }
            }
        }
    }

    /// Long-running prefetch worker. Reads packets sequentially (file
    /// I/O is cheap and FileHandle isn't thread-safe; serializing it
    /// here is correct + simpler), then dispatches each frame's
    /// CPU-bound decompress to an independent `Task` inside a
    /// `TaskGroup`. The TaskGroup is sized by the ring window: up to
    /// `prefetchAheadFrames` decompresses run in parallel, naturally
    /// using the M4's P-cores.
    ///
    /// A single DXV frame's payload is not splittable mid-stream (its
    /// copy operations reach back into earlier output), so we parallelize
    /// at the FRAME boundary instead: each frame's input and output are
    /// independent, and each task has its own `DXVFrameDecoder`.
    private func prefetchLoop(total: Int, ahead: Int) async {
        while !Task.isCancelled {
            let snap = await prefetchState.snapshot()
            let display = snap.display

            // Compute which frames in window [display+1, display+ahead]
            // are missing (not in ring and not inflight). Wrap modulo
            // total so the loop's last frames trigger early prefetch
            // of the loop's first frames.
            var toReserve: [Int] = []
            toReserve.reserveCapacity(ahead)
            for offset in 1...ahead {
                let f = (display + offset) % total
                if snap.ring.contains(f) || snap.inflight.contains(f) { continue }
                if await prefetchState.reserve(f) {
                    toReserve.append(f)
                }
            }

            if toReserve.isEmpty {
                // Window full — wait briefly for the display to advance.
                try? await Task.sleep(nanoseconds: 1_000_000)  // 1 ms
                continue
            }

            // Sequential file reads, parallel decompresses.
            await withTaskGroup(of: Void.self) { group in
                for f in toReserve {
                    let entry = index.frames[f]
                    let pkt: Data
                    do {
                        try fileHandle.seek(toOffset: entry.fileOffset)
                        guard let read = try fileHandle.read(upToCount: Int(entry.size)),
                              read.count == Int(entry.size) else {
                            await prefetchState.cancelReservation(f)
                            continue
                        }
                        pkt = read
                    } catch {
                        await prefetchState.cancelReservation(f)
                        continue
                    }

                    let frameIdx = f
                    group.addTask(priority: .userInitiated) { [weak self] in
                        guard let self = self else { return }
                        let started = CACurrentMediaTime()
                        do {
                            let kind = try Self.decodeKind(packet: pkt, decoder: DXVFrameDecoder(index: self.index))
                            let elapsed = (CACurrentMediaTime() - started) * 1000.0
                            await self.prefetchState.deposit(
                                DecodedFrameEntry(frameIdx: frameIdx, kind: kind, decodeMs: elapsed)
                            )
                        } catch {
                            await self.prefetchState.cancelReservation(frameIdx)
                            DispatchQueue.main.async { [weak self] in
                                self?.onDecodeError?(frameIdx, error)
                            }
                        }
                    }
                }
            }
        }
    }
}
