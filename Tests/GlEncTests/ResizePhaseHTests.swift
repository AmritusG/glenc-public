/*
 * ResizePhaseHTests — Resize Release Phase H (named custom presets, Q5).
 *
 * Three test classes:
 *
 *   NamedSizeTests — value-type tests: Codable round-trip, equality,
 *     displayLabel format. Pure GlEncCore.
 *
 *   AppSettingsCustomPresetsTests — persistence tests through a
 *     suite-named UserDefaults: JSON round-trip, missing/corrupt
 *     stored-value falls back to []; add-preset duplicate-name
 *     replace-by-name policy; remove-preset.
 *
 *   NamedPresetEndToEndTests — proves named presets are a UI
 *     shortcut, not a new code path: an EncodeJob whose outputSize
 *     was set from a NamedSize's (w, h) encodes byte-identically to
 *     a job set to .custom(same w, same h). 1080p-class source per
 *     the standing rule.
 */

import XCTest
import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
@testable import GlEnc
@testable import GlEncCore

// MARK: - NamedSize value-type

final class NamedSizeTests: XCTestCase {

    func testDisplayLabelFormat() {
        let p = NamedSize(name: "Wall A", width: 1500, height: 844)
        XCTAssertEqual(p.displayLabel, "Wall A — 1500×844")
    }

    func testCodableRoundTrip() throws {
        let original = NamedSize(name: "Stage Front", width: 1920, height: 1080)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NamedSize.self, from: data)
        XCTAssertEqual(decoded, original,
                       "NamedSize must round-trip through JSON unchanged")
        XCTAssertEqual(decoded.id, original.id, "id survives the round-trip")
    }

    func testArrayCodableRoundTrip() throws {
        let list: [NamedSize] = [
            NamedSize(name: "A", width: 1024, height: 768),
            NamedSize(name: "B", width: 1920, height: 1080),
            NamedSize(name: "C", width: 2560, height: 1440),
        ]
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode([NamedSize].self, from: data)
        XCTAssertEqual(decoded, list)
    }

    /// Two NamedSizes with different ids but same name/dims are NOT
    /// equal — id is part of the type's identity (Hashable +
    /// Identifiable). Spot-check so the persistence id-preservation
    /// behavior in AppSettings.addCustomPreset is observable.
    func testDistinctIdsAreNotEqual() {
        let a = NamedSize(name: "A", width: 1024, height: 768)
        let b = NamedSize(name: "A", width: 1024, height: 768)
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - AppSettings.customPresets persistence

@MainActor
final class AppSettingsCustomPresetsTests: XCTestCase {

    /// Build a fresh AppSettings backed by an isolated UserDefaults
    /// suite so tests don't see (or pollute) the real production
    /// store. Mirrors the established pattern for AppSettings tests.
    private func makeSettings(_ suiteName: String = "phaseH-\(UUID().uuidString)")
        -> (AppSettings, UserDefaults) {
        let d = UserDefaults(suiteName: suiteName)!
        d.removePersistentDomain(forName: suiteName)
        let s = AppSettings(userDefaults: d)
        return (s, d)
    }

    func testDefaultIsEmpty() {
        let (s, _) = makeSettings()
        XCTAssertEqual(s.customPresets, [])
    }

    /// Add → second AppSettings sees the same list via the same
    /// suite. Confirms the didSet → JSON encode → init JSON decode
    /// loop.
    func testAddPersistsAcrossInits() {
        let (s1, d) = makeSettings("phaseH-persist-\(UUID().uuidString)")
        s1.addCustomPreset(NamedSize(name: "Wall A", width: 1500, height: 844))
        let s2 = AppSettings(userDefaults: d)
        XCTAssertEqual(s2.customPresets.count, 1)
        XCTAssertEqual(s2.customPresets.first?.name, "Wall A")
        XCTAssertEqual(s2.customPresets.first?.width, 1500)
        XCTAssertEqual(s2.customPresets.first?.height, 844)
    }

    /// Corrupt stored data (non-JSON or wrong shape) falls back to
    /// []. Mirrors the Phase C corrupt-fallback contract for
    /// defaultOutputSize.
    func testCorruptStoredValueFallsBackToEmpty() {
        let suite = "phaseH-corrupt-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        // Write garbage bytes under the customPresets key.
        d.set(Data([0x00, 0xFF, 0xAB, 0xCD]), forKey: "glenc.customPresets")
        let s = AppSettings(userDefaults: d)
        XCTAssertEqual(s.customPresets, [],
                       "corrupt JSON must fall back to [] (matches Phase C pattern)")
    }

    /// Wrong-shape JSON (decodes as JSON but not as [NamedSize])
    /// also falls back to []. Belt + suspenders for the try? path.
    func testWrongShapeJSONFallsBackToEmpty() {
        let suite = "phaseH-wrongshape-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set("{\"not\": \"a list\"}".data(using: .utf8), forKey: "glenc.customPresets")
        let s = AppSettings(userDefaults: d)
        XCTAssertEqual(s.customPresets, [])
    }

    /// Duplicate-name policy: replace-by-name. Re-adding "Wall A"
    /// with new dims overwrites the existing entry; the id is
    /// preserved so the SwiftUI list binding sees an update, not a
    /// remove+insert.
    func testDuplicateNameReplacesByName() {
        let (s, _) = makeSettings()
        s.addCustomPreset(NamedSize(name: "Wall A", width: 1500, height: 844))
        let originalID = s.customPresets[0].id
        s.addCustomPreset(NamedSize(name: "Wall A", width: 2000, height: 1124))
        XCTAssertEqual(s.customPresets.count, 1,
                       "duplicate name must NOT append a second entry")
        XCTAssertEqual(s.customPresets[0].width, 2000, "dims must be replaced")
        XCTAssertEqual(s.customPresets[0].height, 1124)
        XCTAssertEqual(s.customPresets[0].id, originalID,
                       "id of the replaced entry must be preserved")
    }

    /// Trimming applies to both the new name AND the duplicate
    /// match. "  Wall A " and "Wall A" collide.
    func testWhitespaceTrimmedOnAddAndMatch() {
        let (s, _) = makeSettings()
        s.addCustomPreset(NamedSize(name: "Wall A", width: 1500, height: 844))
        s.addCustomPreset(NamedSize(name: "  Wall A  ", width: 2000, height: 1124))
        XCTAssertEqual(s.customPresets.count, 1)
        XCTAssertEqual(s.customPresets[0].name, "Wall A",
                       "stored name must be trimmed")
        XCTAssertEqual(s.customPresets[0].width, 2000)
    }

    /// Duplicate-name matching is case-insensitive so "wall a" /
    /// "Wall A" / "WALL A" collide. Matches the savePresetNote
    /// preview in ResizeCustomSheet — kept consistent so the note
    /// and the action never diverge.
    func testDuplicateNameMatchIsCaseInsensitive() {
        let (s, _) = makeSettings()
        s.addCustomPreset(NamedSize(name: "Wall A", width: 1500, height: 844))
        s.addCustomPreset(NamedSize(name: "wall a", width: 2000, height: 1124))
        XCTAssertEqual(s.customPresets.count, 1,
                       "case-only difference must collide")
        XCTAssertEqual(s.customPresets[0].width, 2000)
    }

    /// Empty-after-trim name is rejected (no preset added).
    func testEmptyNameRejected() {
        let (s, _) = makeSettings()
        s.addCustomPreset(NamedSize(name: "   ", width: 1500, height: 844))
        XCTAssertEqual(s.customPresets, [])
    }

    func testRemoveByID() {
        let (s, _) = makeSettings()
        s.addCustomPreset(NamedSize(name: "A", width: 1024, height: 768))
        s.addCustomPreset(NamedSize(name: "B", width: 1920, height: 1080))
        let bID = s.customPresets[1].id
        s.removeCustomPreset(id: bID)
        XCTAssertEqual(s.customPresets.count, 1)
        XCTAssertEqual(s.customPresets[0].name, "A")
    }

    func testRemoveUnknownIDIsNoOp() {
        let (s, _) = makeSettings()
        s.addCustomPreset(NamedSize(name: "A", width: 1024, height: 768))
        s.removeCustomPreset(id: UUID())
        XCTAssertEqual(s.customPresets.count, 1)
    }

    func testResetToDefaultsClearsList() {
        let (s, _) = makeSettings()
        s.addCustomPreset(NamedSize(name: "A", width: 1024, height: 768))
        s.resetToDefaults()
        XCTAssertEqual(s.customPresets, [])
    }
}

// MARK: - End-to-end: named preset == .custom shortcut

@MainActor
final class NamedPresetEndToEndTests: XCTestCase {

    private static var sharedSourceURL: URL?

    /// 1920×1080 procedural H.264 source — diagonal gradient. Same
    /// pattern as ResizePhaseETests' source. We reuse a single file
    /// across tests to keep wall-time small.
    private func makeSource() throws -> URL {
        if let url = Self.sharedSourceURL, FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let dst = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phaseH-src-\(UUID().uuidString).mov")
        let w = 1920, h = 1080, fps: Int32 = 30, frames = 4
        let writer = try AVAssetWriter(outputURL: dst, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw NSError(domain: "PhaseH", code: 1) }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let buf = pb else { throw NSError(domain: "PhaseH", code: 2) }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<h {
                let row = base.advanced(by: y * bpr)
                for x in 0..<w {
                    let p = row.advanced(by: x * 4)
                    p[0] = UInt8(((x + i) & 0xFF))      // B
                    p[1] = UInt8(((y + i) & 0xFF))      // G
                    p[2] = UInt8(((x + y + i) & 0xFF))  // R
                    p[3] = 0xFF
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        Self.sharedSourceURL = dst
        return dst
    }

    private func runDXT1(sourceURL: URL, outputSize: OutputSize) async throws -> URL {
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("phaseH-out-\(UUID().uuidString).mov")
        let pipeline = EncodePipeline(
            sourceURL: sourceURL,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(
                    destURL: outURL,
                    format: .dxt1,
                    presentationWidth: w,
                    presentationHeight: h,
                    fps: fps,
                    codecFourCC: DXVFormat.dxt1.streamFourCC)
            },
            sourceAlphaInfo: .noneSkipLast,
            outputSize: outputSize,
            resizeQuality: .bilinear,
            aspectMode: .distortToFill)
        try await pipeline.run()
        return outURL
    }

    /// A NamedSize applied as outputSize = .custom(w, h) MUST produce
    /// a byte-identical encode to the same .custom built directly.
    /// Proves named presets are pure UI sugar over .custom.
    func testNamedPresetEncodesIdenticalToCustomShortcut() async throws {
        let src = try makeSource()
        let preset = NamedSize(name: "Wall A", width: 1500, height: 844)

        let outNamed = try await runDXT1(
            sourceURL: src,
            outputSize: .custom(width: preset.width, height: preset.height))
        defer { try? FileManager.default.removeItem(at: outNamed) }

        let outCustom = try await runDXT1(
            sourceURL: src,
            outputSize: .custom(width: 1500, height: 844))
        defer { try? FileManager.default.removeItem(at: outCustom) }

        let namedBytes = try Data(contentsOf: outNamed)
        let customBytes = try Data(contentsOf: outCustom)
        XCTAssertEqual(namedBytes, customBytes,
                       "Named preset and direct .custom with same dims must encode byte-identically — named presets are a UI shortcut, not a separate code path")
    }
}
