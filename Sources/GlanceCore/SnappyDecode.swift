// SPDX-License-Identifier: MIT
import Foundation
import SnappyC

/// Thin Swift front end over the vendored C Snappy (`SnappyC`), exposing only
/// what the HAP decode path needs: block decompression.
///
/// **Why this exists.** It replaces `lovetodream/swift-snappy`'s `Snappy`
/// product, whose `_uncompress` wrapped the freshly `allocate()`d output buffer
/// in `Data(bytesNoCopy:count:deallocator: .none)` — so the `Data` freed but the
/// malloc'd backing buffer was *never* released. That leaked one output-sized
/// buffer (the decompressed DXT payload, ~2–3 MB for a 1080p Hap5 frame) on
/// every decompress call; in continuous looping playback it climbed ~3 MB/frame
/// and jetsam-killed iCrate at the per-process limit. Here the buffer is given
/// an owning deallocator, so it is freed when the `Data` dies.
enum SnappyDecode {

    enum Error: Swift.Error, CustomStringConvertible {
        case lengthUnreadable
        case uncompressFailed(Int32)
        var description: String {
            switch self {
            case .lengthUnreadable:
                return "SnappyDecode: could not read uncompressed length (corrupt header?)"
            case .uncompressFailed(let code):
                return "SnappyDecode: snappy_uncompress failed (error \(code))"
            }
        }
    }

    /// Decompress a Snappy block into raw bytes. The returned `Data` owns its
    /// backing buffer (freed on release) — no `.none` deallocator, no leak.
    static func uncompress(_ input: Data) throws -> Data {
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) throws -> Data in
            guard let base = raw.baseAddress, input.count > 0 else { return Data() }
            let inPtr = base.assumingMemoryBound(to: CChar.self)

            var outLen = 0
            guard snappy_uncompressed_length(inPtr, input.count, &outLen) else {
                throw Error.lengthUnreadable
            }
            // Allocate the output, decompress, and hand the buffer to `Data`
            // with an OWNING deallocator that frees it (the whole point of the
            // fix). `.deallocate()` matches `UnsafeMutablePointer.allocate`.
            let outBuf = UnsafeMutablePointer<CChar>.allocate(capacity: max(1, outLen))
            let err = snappy_uncompress(inPtr, input.count, outBuf)
            guard err == 0 else {
                outBuf.deallocate()
                throw Error.uncompressFailed(Int32(abs(err)))
            }
            return Data(
                bytesNoCopy: outBuf,
                count: outLen,
                deallocator: .custom { ptr, _ in ptr.deallocate() }
            )
        }
    }
}
