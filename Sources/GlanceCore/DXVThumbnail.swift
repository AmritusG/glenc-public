// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics
import DXVKit

/// High-level helper that takes a DXV file URL and produces a CGImage of
/// frame 0 (thumbnails, Quick Look). Decoded entirely by DXVKit: demux,
/// packet decode and RGBA conversion (`dxvk_blocks_to_rgba`). YCG6 / YG10
/// come out in Resolume Arena's colour convention (chroma midpoint 127.5,
/// nearest chroma, R / B overflow folding); alpha is passed through
/// unpremultiplied-labelled, as before.
public enum DXVThumbnail {

    public enum ThumbnailError: Error, CustomStringConvertible {
        case notADXVFile(fourCC: String?)
        case noFrames
        case readShort(needed: Int, got: Int)
        case decodeFailed(underlying: Error)
        public var description: String {
            switch self {
            case .notADXVFile(let cc): return "Not a DXV file (FourCC=\(cc ?? "<unknown>"))"
            case .noFrames: return "DXV file has no frames"
            case .readShort(let n, let g): return "Read short: needed \(n), got \(g)"
            case .decodeFailed(let e): return "Decode failed: \(e)"
            }
        }
    }

    /// Decode frame 0 of the DXV file at `url` and return it as a CGImage.
    /// Throws `ThumbnailError.notADXVFile` for other codecs (callers use this
    /// to let the system handle the file).
    public static func cgImageOfFirstFrame(at url: URL) throws -> CGImage {
        // Quick FourCC pre-check so a 10 GB H.264 file fails fast. Sample-entry
        // FourCCs Resolume Arena accepts: DXD3 / DXD4 (DXV3), DXDI (legacy);
        // "DXV3" kept for old callers' files.
        let fourCC = DXVDetector.compressorFourCC(at: url)
        guard let fourCC, ["DXV3", "DXD3", "DXD4", "DXDI"].contains(fourCC) else {
            throw ThumbnailError.notADXVFile(fourCC: fourCC)
        }
        let movie: DXVMovie
        do { movie = try DXVMovie(url: url) } catch { throw ThumbnailError.decodeFailed(underlying: error) }
        guard movie.frameCount > 0 else { throw ThumbnailError.noFrames }
        do {
            let rgba = try movie.decodeRGBA(at: 0)
            return try CPURender.cgImageFromRGBA(rgba: [UInt8](rgba), width: movie.width, height: movie.height)
        } catch {
            throw ThumbnailError.decodeFailed(underlying: error)
        }
    }
}
