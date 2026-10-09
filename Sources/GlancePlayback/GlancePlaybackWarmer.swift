// SPDX-License-Identifier: MIT
import Foundation
import Metal

/// Cold-start primer for the Metal playback path. The FIRST Metal pipeline
/// compiled in a process pays the shader-compile cost (the renderers' inline
/// MSL is compiled at runtime via `makeLibrary` + `makeRenderPipelineState`,
/// ~hundreds of ms); Metal then caches compiled pipelines process-wide, so a
/// later renderer of the same kind is a cache hit. Without priming, the FIRST
/// clip opened after launch stutters while its renderer's pipelines compile.
///
/// `prewarm()` mirrors iCrate's app-local `PlaybackWarmer`: it constructs each
/// renderer ONCE early, off-main, and DISCARDS it — warming the cache before
/// the user opens any clip (FORK 3: construct-and-discard, not a shared cached
/// pipeline; the real player later builds its own pipeline as a cache hit).
/// It supersedes that app-local warmer — the DXV half now, and the HAP half
/// once consumers adopt the hoisted `RGBAQuadRenderer`.
///
/// Safety: priming COMPILES SHADERS ONLY — it uploads nothing, decodes
/// nothing, encodes nothing (no DXV3/HAP byte path, no audio, no UI). Each
/// renderer is `try?` so one warm failure can't block the other or playback.
/// No player or renderer is altered to consult this; the effect is purely the
/// process-wide Metal pipeline cache.
public enum GlancePlaybackWarmer {

    #if os(iOS)
    private static let warmLock = NSLock()
    private static var didWarm = false
    #endif

    /// Prime the Metal pipeline caches for the iOS playback renderers. Safe to
    /// call repeatedly (runs at most once per process) and from any thread;
    /// the construction happens on a detached utility task so the shader
    /// compile never hitches the caller. Pass a `device` to pin a specific GPU,
    /// or leave nil to use the system default. `colorPixelFormat` must match
    /// the consuming MTKView's format (`.bgra8Unorm` for the iCrate hosts).
    ///
    /// macOS: a documented no-op — see the type doc. There is no Metal renderer
    /// to prime on Mac.
    public static func prewarm(device: MTLDevice? = nil,
                               colorPixelFormat: MTLPixelFormat = .bgra8Unorm) {
        #if os(iOS)
        warmLock.lock()
        let alreadyWarmed = didWarm
        didWarm = true
        warmLock.unlock()
        if alreadyWarmed { return }

        let requestedDevice = device
        let pixelFormat = colorPixelFormat
        // Detached (off any inherited actor) so the GPU shader compile runs off
        // the main thread — no UI hitch at launch.
        Task.detached(priority: .utility) {
            guard let dev = requestedDevice ?? MTLCreateSystemDefaultDevice() else { return }
            // Construct-and-discard to prime Metal's process-wide pipeline cache.
            // (a) DXV — MetalDXVRenderer: shader library + 5 pipeline states.
            _ = try? MetalDXVRenderer(device: dev, colorPixelFormat: pixelFormat)
            // (b) HAP — RGBAQuadRenderer: shader library + 2 pipeline states.
            _ = try? RGBAQuadRenderer(device: dev, colorPixelFormat: pixelFormat)
        }
        #else
        // macOS: documented no-op. The Mac DXV path is the OpenGL `DXVRenderer`
        // (shaders compiled lazily in `ensureGLObjects`), which Mac HAP shares.
        // It does not consume a Metal pipeline, so nothing primed here would
        // be used — and `MetalDXVRenderer` is `#if os(iOS)`, so it cannot be
        // referenced on macOS. Kept callable cross-platform for a single API.
        _ = (device, colorPixelFormat)
        #endif
    }
}
