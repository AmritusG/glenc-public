// SPDX-License-Identifier: MIT
import Foundation

/// One decoded video frame's location in a DXV MOV file. The byte range
/// described here points at the *full* DXV packet (12-byte header +
/// payload). The demuxer doesn't strip the header — that happens in the
/// per-frame decoder where we also need the header's raw_flag to decide
/// whether to LZF-decompress.
public struct DXVFrameEntry {
    public let fileOffset: UInt64
    public let size: UInt32
    public let presentationTime: Double  // seconds from start
    public init(fileOffset: UInt64, size: UInt32, presentationTime: Double) {
        self.fileOffset = fileOffset
        self.size = size
        self.presentationTime = presentationTime
    }
}

/// Codec variant identified at the trak's sample description. Drives both
/// the LZF/DXT decode path and the GPU upload format chosen by the
/// renderer. Texture format only; codec generation (DXV1 vs DXV3 packet
/// shape) is carried by `DXVGeneration` on the surrounding index.
public enum DXVVariant {
    case dxt1   // DXV3 normal, no alpha     → GL_COMPRESSED_RGB_S3TC_DXT1_EXT
    case dxt5   // DXV3 normal, with alpha   → GL_COMPRESSED_RGBA_S3TC_DXT5_EXT
    case ycg6   // DXV3 HQ, no alpha         → custom shader (Phase 2)
    case yg10   // DXV3 HQ, with alpha       → custom shader (Phase 2)

    /// Human-readable label for the title bar / debugging.
    public var displayName: String {
        switch self {
        case .dxt1: return "DXV3"
        case .dxt5: return "DXV3 alpha"
        case .ycg6: return "DXV3 HQ"
        case .yg10: return "DXV3 HQ alpha"
        }
    }
}

/// Codec generation, derived from the trak-level sample-description
/// FourCC. Orthogonal to `DXVVariant` (which is texture format). DXV1
/// and DXV3 differ at the *packet* level — header shape, compression
/// scheme — but agree at the *texture* level (raw DXT1/DXT5 blocks).
///
/// `dxv1`: trak FourCC `DXDI`. 4-byte legacy header, payload is RAW or
/// LZF-compressed DXT blocks. Only `.dxt1` / `.dxt5` variants exist.
/// `dxv3`: trak FourCC `DXD3` (or the texture-format tags). 12-byte
/// header, DXV-specific opcode-based decompression. All four variants.
public enum DXVGeneration {
    case dxv1
    case dxv3
}

/// Complete index built by demuxing a DXV MOV file. After this is built,
/// random-access seek is O(1): just look up frames[i].
public struct DXVMovieIndex {
    public let width: Int
    public let height: Int
    public let variant: DXVVariant
    /// Codec generation. `.dxv3` for the modern Resolume DXV3 family
    /// (trak FourCC `DXD3` or the texture-format tags), `.dxv1` for the
    /// legacy DXV1/DXV2 (trak FourCC `DXDI`). Defaults to `.dxv3` in
    /// the convenience init so prior callers compile unchanged.
    public let generation: DXVGeneration
    public let frames: [DXVFrameEntry]
    /// Total movie duration in seconds.
    public let duration: Double
    /// Average frame rate (frames / duration). Most DXV is CFR; this is
    /// fine for the player clock.
    public var frameRate: Double { duration > 0 ? Double(frames.count) / duration : 30.0 }
    public init(width: Int, height: Int, variant: DXVVariant,
                generation: DXVGeneration = .dxv3,
                frames: [DXVFrameEntry], duration: Double) {
        self.width = width
        self.height = height
        self.variant = variant
        self.generation = generation
        self.frames = frames
        self.duration = duration
    }
}

public enum DXVDemuxError: Error, CustomStringConvertible {
    case fileOpen(String)
    case truncated(String)
    case unsupported(String)
    case missingAtom(String)
    case notDXV(fourCC: String)

    public var description: String {
        switch self {
        case .fileOpen(let s):    return "File open failed: \(s)"
        case .truncated(let s):   return "File truncated: \(s)"
        case .unsupported(let s): return "Unsupported format: \(s)"
        case .missingAtom(let s): return "Missing required atom: \(s)"
        case .notDXV(let f):      return "Not a DXV file (codec FourCC: \(f))"
        }
    }
}

/// Frame index for a DXV QuickTime file, built by DXVKit's demuxer
/// (`DXVKitBridge.movieIndex`): track size, one entry per sample (file offset,
/// size, presentation time), the variant and generation of the first packet
/// (the packet decides, as in Resolume Arena: a legacy packet in a `DXD3`
/// track is legacy), and the duration. Accepts the sample-entry FourCCs
/// Arena accepts: `DXD3`, `DXD4` and `DXDI`.
///
/// Presentation times are `index x frame duration` (DXVKit reports the first
/// sample duration); on the few files whose sample durations vary they can
/// differ from the per-sample times by well under a frame.
public final class DXVDemuxer {

    /// Parse a DXV MOV file at `url` and return its frame index. Throws on
    /// malformed or non-DXV files.
    public static func demux(url: URL) throws -> DXVMovieIndex {
        try DXVKitBridge.movieIndex(url: url)
    }
}
