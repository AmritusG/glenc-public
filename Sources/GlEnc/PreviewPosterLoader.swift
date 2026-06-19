// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import AVFoundation
import GlanceCore

/// Loads a single poster frame (frame 0) for a given URL. The Phase 8B
/// preview pane displays this while it has no live player attached
/// (post-Phase-8B-b that's every state; later phases replace the
/// poster with `DXVPlayer` once playback is wired).
///
/// Routing:
///   - DXV3 sources (FourCCs DXT1 / DXT5 / YCG6 / YG10 / DXDI / DXD3) →
///     `GlanceCore.DXVThumbnail.cgImageOfFirstFrame(at:)`. This uses the
///     same `CPURender` path GlEnc consumed elsewhere; no GL context
///     required.
///   - Everything else (ProRes / H.264 / MP4 / HAP / etc.) →
///     `AVAssetImageGenerator.copyCGImage(at: .zero, ...)`. Standard
///     macOS path with full VideoToolbox decoder coverage.
///
/// The split mirrors `SourceFrameReader`'s factory: macOS has no DXV3
/// decoder registered with VideoToolbox, so DXV3 files must route
/// through GlanceCore.
enum PreviewPosterLoader {

    enum LoadError: Error, CustomStringConvertible {
        case avAssetGenerator(Error)
        case dxvThumbnail(Error)
        case hapThumbnail(Error)

        var description: String {
            switch self {
            case .avAssetGenerator(let e): return "AVAssetImageGenerator failed: \(e.localizedDescription)"
            case .dxvThumbnail(let e):     return "DXVThumbnail failed: \(e.localizedDescription)"
            case .hapThumbnail(let e):     return "HAPThumbnail failed: \(e.localizedDescription)"
            }
        }
    }

    /// Compressor FourCCs that route to the GlanceCore path. Matches
    /// the set used by `SourceFrameReader.makeSourceReader`.
    private static let dxvFourCCs: Set<String> = [
        "DXT1", "DXT5", "YCG6", "YG10", "DXDI", "DXD3",
    ]

    /// Load frame 0 of the given URL as a CGImage. Synchronous;
    /// callers should wrap in `Task.detached` for off-main-thread I/O.
    static func loadPoster(for url: URL) throws -> CGImage {
        // HAP first — checked separately from the dxvFourCCs gate, since
        // HAP routes to HAPThumbnail (DXVThumbnail throws notADXVFile for
        // HAP FourCCs). Mirrors PreviewPlayerModel.load(url:)'s ordering.
        if HAPDetector.compressorFourCCIfHAP(at: url) != nil {
            do {
                return try HAPThumbnail.cgImageOfFirstFrame(at: url)
            } catch {
                throw LoadError.hapThumbnail(error)
            }
        }
        if let cc = DXVDetector.compressorFourCC(at: url), dxvFourCCs.contains(cc) {
            do {
                return try DXVThumbnail.cgImageOfFirstFrame(at: url)
            } catch {
                throw LoadError.dxvThumbnail(error)
            }
        }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        do {
            return try gen.copyCGImage(at: .zero, actualTime: nil)
        } catch {
            throw LoadError.avAssetGenerator(error)
        }
    }
}
