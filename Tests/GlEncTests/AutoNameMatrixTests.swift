/*
 * Exhaustive AutoNameEngine matrix — every codec × container × trim-state
 * × fps, asserting the token, the container-derived extension, and that a
 * valid fps never produces the [00.00.00-00.00.00] placeholder bracket
 * (the trim-naming bug). Pure-function coverage of all naming conventions.
 */
import XCTest
import GlEncCore
@testable import GlEnc

final class AutoNameMatrixTests: XCTestCase {

    private let src = URL(fileURLWithPath: "/x/Clip.mov")

    private func name(_ codec: OutputCodec, _ container: OutputContainer,
                      inF: Int?, outF: Int?, fps: Double,
                      _ tf: AppSettings.TrimFilenameFormat = .time) -> String {
        AutoNameEngine.suggestedName(
            sourceURL: src, format: codec.dxvFormat ?? .dxt1, outputCodec: codec,
            container: container, inFrame: inF, outFrame: outF, fps: fps, trimFormat: tf)
    }

    private func expectedToken(_ codec: OutputCodec) -> String {
        switch codec {
        case .dxv(let f):
            switch f {
            case .dxt1: return "_DXV Normal Quality"
            case .dxt5: return "_DXV Normal Quality With Alpha"
            case .ycg6: return "_DXV High Quality"
            case .yg10: return "_DXV High Quality With Alpha"
            default:    return "_\(f.label)"   // HAP variants
            }
        case .prores(let v): return "_\(v.nameToken)"
        case .h264:  return "_H.264"
        case .hevc:  return "_HEVC"
        case .mjpeg: return "_MotionJPEG"
        }
    }

    private var allCodecs: [OutputCodec] {
        let dxv: [OutputCodec] = [.dxt1, .dxt5, .ycg6, .yg10, .hap1, .hap5, .hapY, .hapM].map { .dxv($0) }
        let pro: [OutputCodec] = ProResVariant.allCases.map { .prores($0) }
        return dxv + pro + [.h264, .hevc, .mjpeg]
    }

    func testEveryCombination_TokenExtensionAndTrimBracket() {
        for codec in allCodecs {
            for container in codec.allowedContainers {
                let token = expectedToken(codec)

                // no trim
                let plain = name(codec, container, inF: nil, outF: nil, fps: 24)
                XCTAssertTrue(plain.contains(token), "\(codec)/\(container): token \(token) missing in \(plain)")
                XCTAssertTrue(plain.hasSuffix(".\(container.ext)"), "\(codec)/\(container): wrong extension in \(plain)")
                XCTAssertFalse(plain.contains("["), "\(codec): no trim → no bracket")

                // trimmed, valid fps — MUST NOT be the 00.00.00 placeholder
                for fps in [24.0, 30.0, 30000.0/1001.0] {
                    let trimmed = name(codec, container, inF: 24, outF: 180, fps: fps)
                    XCTAssertTrue(trimmed.contains(token))
                    XCTAssertTrue(trimmed.hasSuffix(".\(container.ext)"))
                    XCTAssertTrue(trimmed.contains("["), "\(codec)/\(container): trim bracket missing")
                    XCTAssertFalse(trimmed.contains("00.00.00-00.00.00"),
                        "\(codec)/\(container) @ \(fps)fps: placeholder bracket on a VALID fps — the trim bug! got \(trimmed)")
                }

                // frame-indices format
                let fi = name(codec, container, inF: 24, outF: 180, fps: 24, .frameIndices)
                XCTAssertTrue(fi.contains("[24-180]"), "\(codec)/\(container): frame-index bracket wrong in \(fi)")
            }
        }
    }

    func testFpsZeroIsTheOnlyPlaceholderCase() {
        // Documents that the placeholder ONLY appears when fps is unknown (0).
        let zero = name(.dxv(.dxt1), .mov, inF: 24, outF: 180, fps: 0)
        XCTAssertTrue(zero.contains("00.00.00-00.00.00"), "fps=0 → placeholder (the only legitimate case)")
        let ok = name(.dxv(.dxt1), .mov, inF: 24, outF: 180, fps: 24)
        XCTAssertFalse(ok.contains("00.00.00-00.00.00"))
    }

    func testOpenEndedOut_ResolvesToClipEnd_NotDuplicateStart() {
        // out = "→ end" (outFrame nil) with a known total frame count must
        // render the clip's END time, not duplicate the in-point.
        // in 67 @ 24fps = 2.79s → 00.02.79 ; end 239 @ 24fps = 9.95s.
        let n = AutoNameEngine.suggestedName(
            sourceURL: src, format: .dxt1, outputCodec: .dxv(.dxt1), container: .mov,
            inFrame: 67, outFrame: nil, fps: 24, totalFrames: 240, trimFormat: .time)
        XCTAssertFalse(n.contains("00.02.79-00.02.79"),
                       "open-ended out must NOT duplicate the in-point — got \(n)")
        XCTAssertTrue(n.contains("[00.02.79-"), "in time present in \(n)")
        XCTAssertTrue(n.contains("-00.09.95]"), "clip end time present in \(n)")
    }

    func testContainerExtensionMatrix() {
        // ProRes/DXV/HAP/MJPEG → .mov; H.264/HEVC → .mov or .mp4.
        XCTAssertTrue(name(.h264, .mp4, inF: nil, outF: nil, fps: 24).hasSuffix(".mp4"))
        XCTAssertTrue(name(.h264, .mov, inF: nil, outF: nil, fps: 24).hasSuffix(".mov"))
        XCTAssertTrue(name(.hevc, .mp4, inF: nil, outF: nil, fps: 24).hasSuffix(".mp4"))
        XCTAssertTrue(name(.prores(.proRes4444), .mov, inF: nil, outF: nil, fps: 24).hasSuffix(".mov"))
        XCTAssertTrue(name(.mjpeg, .mov, inF: nil, outF: nil, fps: 24).hasSuffix(".mov"))
        XCTAssertTrue(name(.dxv(.dxt1), .mov, inF: nil, outF: nil, fps: 24).hasSuffix(".mov"))
    }
}
