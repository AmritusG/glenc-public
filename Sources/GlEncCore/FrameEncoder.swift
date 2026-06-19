// SPDX-License-Identifier: MIT
import Foundation

/// Per-frame encoder protocol. Phase 1's NoOpEncoder returns BGRA bytes
/// unchanged. Phase 2+ DXT1/DXT5/HQ encoders return DXV3-frame bytes
/// (12-byte header + LZ-compressed BC1/BC4/BC5 payload) and the
/// pipeline hands those to the hand-rolled MOV writer instead of
/// AVAssetWriter.
public protocol FrameEncoder {
    /// Called once before the first frame.
    /// `hasAlpha` is informational — drives BC1 vs BC3 vs YG10 selection
    /// in Phase 2+ encoders; ignored by NoOp.
    func prepare(width: Int, height: Int, fps: Double, hasAlpha: Bool) throws

    /// Encode one frame; return the encoded packet bytes.
    /// - NoOp: tightly-packed BGRA (size = width × height × 4)
    /// - DXT1/DXT5/HQ (Phase 2+): full DXV3 frame including 12-byte header
    func encode(frame: PixelFrame) throws -> Data

    /// Called once after the last frame. Lets encoders flush any
    /// internal state (LZ tables, opcode buffers).
    func finish() throws
}
