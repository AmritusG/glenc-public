// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation

/// Reads the FourCC compressor code from the first video track of a MOV/MP4
/// file by walking atoms: `moov → trak → mdia → (hdlr=vide) → minf → stbl →
/// stsd → first entry → bytes [4..<8]`.
///
/// Cheap: only atom headers (8 bytes each) are read, so even a 10GB file
/// resolves in a handful of small disk reads. Returns nil for non-MOV/MP4
/// input, files without a video track, or any parse error.
public enum DXVDetector {

    public static func compressorFourCC(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd() else { return nil }
        guard let moov = findTopLevelAtom(handle: handle,
                                          type: "moov",
                                          fileSize: fileSize) else { return nil }
        return findVideoFourCC(handle: handle, in: moov)
    }

    /// Maps known FourCC codes to friendly display names. DXV/HAP codes are
    /// returned as-is — those names ARE the display name in the VJ ecosystem.
    /// Returns nil for codes we don't recognise; the caller should fall back
    /// to showing the raw FourCC.
    public static func displayName(for fourCC: String) -> String? {
        switch fourCC {
        case "DXV3", "DXVA", "DXV1": return fourCC
        case "Hap1": return "HAP"
        case "HapA": return "HAP Alpha"
        case "HapY": return "HAP Q"
        case "HapM": return "HAP Q Alpha"
        case "apch": return "ProRes 422 HQ"
        case "apcn": return "ProRes 422"
        case "apcs": return "ProRes 422 LT"
        case "apco": return "ProRes 422 Proxy"
        case "ap4h": return "ProRes 4444"
        case "ap4x": return "ProRes 4444 XQ"
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "av01":         return "AV1"
        case "vp09":         return "VP9"
        case "mp4v":         return "MPEG-4"
        default:             return nil
        }
    }

    // MARK: - Atom walking

    private struct Atom {
        let type: String
        let headerEnd: UInt64  // first byte of payload
        let atomEnd: UInt64    // first byte AFTER the atom
    }

    private static func readAtomHeader(handle: FileHandle,
                                       at offset: UInt64,
                                       maxEnd: UInt64) -> Atom? {
        guard offset + 8 <= maxEnd else { return nil }
        guard let header = readBytes(handle: handle, at: offset, count: 8) else {
            return nil
        }
        let size32 = readUInt32BE(header, at: 0)
        let type = fourCC(header, at: 4)

        let payloadStart: UInt64
        let totalSize: UInt64
        switch size32 {
        case 1:
            // 64-bit extended size in the next 8 bytes.
            guard let ext = readBytes(handle: handle,
                                      at: offset + 8,
                                      count: 8) else { return nil }
            totalSize = readUInt64BE(ext, at: 0)
            payloadStart = offset + 16
        case 0:
            // Extends to end of container.
            totalSize = maxEnd - offset
            payloadStart = offset + 8
        default:
            totalSize = UInt64(size32)
            payloadStart = offset + 8
        }
        guard totalSize >= 8, offset + totalSize <= maxEnd else { return nil }
        return Atom(type: type,
                    headerEnd: payloadStart,
                    atomEnd: offset + totalSize)
    }

    private static func findTopLevelAtom(handle: FileHandle,
                                         type: String,
                                         fileSize: UInt64) -> Atom? {
        var offset: UInt64 = 0
        while offset < fileSize {
            guard let atom = readAtomHeader(handle: handle,
                                            at: offset,
                                            maxEnd: fileSize) else { return nil }
            if atom.type == type { return atom }
            offset = atom.atomEnd
        }
        return nil
    }

    private static func findChildAtom(handle: FileHandle,
                                      type: String,
                                      in parent: Atom) -> Atom? {
        var offset = parent.headerEnd
        while offset < parent.atomEnd {
            guard let atom = readAtomHeader(handle: handle,
                                            at: offset,
                                            maxEnd: parent.atomEnd) else { return nil }
            if atom.type == type { return atom }
            offset = atom.atomEnd
        }
        return nil
    }

    /// Iterate `trak` atoms in moov; for each, check if it's a video track
    /// (handler == "vide") and if so return the codec FourCC from stsd.
    private static func findVideoFourCC(handle: FileHandle, in moov: Atom) -> String? {
        var offset = moov.headerEnd
        while offset < moov.atomEnd {
            guard let atom = readAtomHeader(handle: handle,
                                            at: offset,
                                            maxEnd: moov.atomEnd) else { return nil }
            if atom.type == "trak",
               let cc = videoFourCCInTrak(handle: handle, trak: atom) {
                return cc
            }
            offset = atom.atomEnd
        }
        return nil
    }

    private static func videoFourCCInTrak(handle: FileHandle, trak: Atom) -> String? {
        guard let mdia = findChildAtom(handle: handle, type: "mdia", in: trak),
              let hdlr = findChildAtom(handle: handle, type: "hdlr", in: mdia)
        else { return nil }

        // hdlr payload layout:
        //   +0  version + flags (4)
        //   +4  pre_defined (4, zero)
        //   +8  handler type (4)  ← "vide" for video tracks
        //   +12 reserved (12)
        //   +24 name (null-terminated UTF-8)
        guard let handlerType = readFourCC(handle: handle,
                                           at: hdlr.headerEnd + 8),
              handlerType == "vide" else { return nil }

        guard let minf = findChildAtom(handle: handle, type: "minf", in: mdia),
              let stbl = findChildAtom(handle: handle, type: "stbl", in: minf),
              let stsd = findChildAtom(handle: handle, type: "stsd", in: stbl)
        else { return nil }

        // stsd payload layout:
        //   +0  version + flags (4)
        //   +4  entry count (4)
        //   +8  first entry begins
        //         entry[0..4)   size (4)
        //         entry[4..8)   data format / FourCC ← what we want
        // → absolute offset for the FourCC: stsd.headerEnd + 12
        return readFourCC(handle: handle, at: stsd.headerEnd + 12)
    }

    // MARK: - Byte helpers

    private static func readBytes(handle: FileHandle,
                                  at offset: UInt64,
                                  count: Int) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count)
            return (data?.count == count) ? data : nil
        } catch {
            return nil
        }
    }

    private static func readFourCC(handle: FileHandle, at offset: UInt64) -> String? {
        guard let data = readBytes(handle: handle, at: offset, count: 4) else {
            return nil
        }
        let s = fourCC(data, at: 0)
        return s.isEmpty ? nil : s
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[start + i]) }
        return v
    }

    private static func readUInt64BE(_ data: Data, at offset: Int) -> UInt64 {
        let start = data.startIndex + offset
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[start + i]) }
        return v
    }

    /// Lenient FourCC reader — returns "" on bad bytes rather than nil so the
    /// atom walker can keep going past unknown atom types.
    private static func fourCC(_ data: Data, at offset: Int) -> String {
        let start = data.startIndex + offset
        let bytes = data[start ..< start + 4]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
