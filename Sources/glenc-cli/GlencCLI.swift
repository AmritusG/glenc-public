// SPDX-License-Identifier: MIT
//
// glenc-cli — a thin headless front-end over GlEncCore.
//
// The GUI (Sources/GlEnc) and this CLI both drive the SAME encode path:
// `CoreEncoder.makePipeline(...)` in GlEncCore. No encode logic lives
// here — this target only parses arguments, makes ONE call into the
// core, and maps success/failure to a process exit code. The priority
// codecs are DXV (DXD3) and HAP (Hap1/Hap5/HapY/HapA/HapM) — exactly the
// formats ffmpeg cannot mint (it has no HAP encoder at all). The
// AVAssetWriter codecs (ProRes/H.264/HEVC/MJPEG) come along for free
// because their sink already lives in the shared core.
//
// Async note: `EncodePipeline.run()` is async. `AsyncParsableCommand`
// drives it on the Swift concurrency main executor, so no manual
// CFRunLoop is needed — the awaited pipeline completes before `run()`
// returns. The DXV/HAP writer is fully synchronous file I/O; the
// AVAssetWriter sinks block on their own DispatchSemaphore inside
// `finish()`. Either way the call is complete when `run()` returns.

import Foundation
import CoreGraphics
import ArgumentParser
import GlEncCore

@main
struct GlencCLI: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "glenc-cli",
        abstract: "Headless DXV/HAP (and ProRes/H.264/HEVC/MJPEG) encoder over GlEncCore.",
        discussion: """
        Encodes one input video to one output file. DXV (DXD3) and HAP are
        the priority — the formats ffmpeg cannot produce. Validate output
        independently (ffprobe FourCC + GlanceCore demux / libmpv decode);
        do not trust this tool's own exit code as proof of correctness.

        Codec values:
          DXV3:  dxt1  dxt5  ycg6  yg10
          HAP:   hap1  hap5  hapy  hapa  hapm
          ProRes: prores422  prores422hq  prores422lt  prores422proxy  prores4444
          Other:  h264  hevc  mjpeg
        """,
        version: "glenc-cli 1.0.0"
    )

    @Argument(help: "Input video path (any AVFoundation-readable container, or a DXV3 .mov).")
    var input: String

    @Argument(help: "Output file path.")
    var output: String

    @Option(name: [.short, .long],
            help: "Codec/variant. See the discussion above for the full list.")
    var codec: String = "dxt1"

    @Option(name: .long, help: "Container: mov or mp4 (mp4 only valid for h264/hevc).")
    var container: String = "mov"

    @Option(name: .long, help: "Output width (with --height, forces a resize to WxH).")
    var width: Int?

    @Option(name: .long, help: "Output height (with --width, forces a resize to WxH).")
    var height: Int?

    @Option(name: .long, help: "Resize filter: auto, nearest, bilinear, lanczos.")
    var resizeQuality: String = "auto"

    @Option(name: .long, help: "Aspect handling on resize: letterbox or distortToFill.")
    var aspect: String = "letterbox"

    @Option(name: .long, help: "Crop rect in source pixels as x:y:w:h (top-left origin).")
    var crop: String?

    @Option(name: .long, help: "Trim to source frames [start, end) as start:end.")
    var trim: String?

    @Flag(name: .long, inversion: .prefixedNo,
          help: "Pass through the source audio track (default: on).")
    var audio: Bool = true

    @Option(name: .long,
            help: "HAP chunked-section count (hap1/hap5/hapy/hapa/hapm). 1 = single section (default); 2-64 = multi-chunk (Hap1 0xCB / Hap5 0xCE / HapY 0xCF / HapA 0xC1; HapM 0x0D wrapping 0xCF color + 0xC1 alpha).")
    var chunks: Int = 1

    @Option(name: .long, help: "Encoding-software string stamped into udta/©swr.")
    var writerVersion: String = "glenc-cli 1.0.0"

    @Flag(name: .long, help: "Print resolved settings before encoding.")
    var verbose: Bool = false

    mutating func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ValidationError("input file not found: \(inputURL.path)")
        }

        let parsedCodec = try Self.parseCodec(codec)
        let parsedContainer = try Self.parseContainer(container, codec: parsedCodec)
        guard (1...64).contains(chunks) else {
            throw ValidationError("--chunks must be in 1...64 (got \(chunks))")
        }
        let outputSize = try Self.parseOutputSize(width: width, height: height)
        let cropRect = try crop.map(Self.parseCrop)
        let frameRange = try trim.map(Self.parseTrim)

        guard let rq = ResizeQuality(rawValue: resizeQuality) else {
            throw ValidationError("invalid --resize-quality: \(resizeQuality) (auto|nearest|bilinear|lanczos)")
        }
        guard let am = AspectMode(rawValue: aspect) else {
            throw ValidationError("invalid --aspect: \(aspect) (letterbox|distortToFill)")
        }

        // Audio pass-through (optional). Read via the shared core reader so
        // the CLI carries audio exactly as the GUI does. A source with no
        // audio track simply yields nil (no warning, no track).
        var audioData: (info: AudioStreamInfo, pcm: Data)?
        if audio {
            do {
                if let read = try await SourceAudioReader.readInterleavedPCM(inputURL, targetRate: nil),
                   !read.pcm.isEmpty {
                    audioData = (read.info, read.pcm)
                    if verbose {
                        FileHandle.standardError.write(Data(
                            "audio: \(read.info.channels)ch @ \(read.info.sampleRate)Hz, \(read.frameCount) frames\n".utf8))
                    }
                }
            } catch {
                // Keep the video; surface the reason on stderr (non-fatal).
                FileHandle.standardError.write(Data(
                    "warning: audio unavailable: \(error)\n".utf8))
            }
        }

        let request = EncodeRequest(
            sourceURL: inputURL,
            outputURL: outputURL,
            codec: parsedCodec,
            container: parsedContainer,
            outputSize: outputSize,
            resizeQuality: rq,
            aspectMode: am,
            cropRect: cropRect,
            frameRange: frameRange,
            writerVersion: writerVersion,
            hapChunks: chunks)

        if verbose {
            FileHandle.standardError.write(Data("""
            glenc-cli encode
              input:   \(inputURL.path)
              output:  \(outputURL.path)
              codec:   \(parsedCodec)
              size:    \(outputSize)
              crop:    \(cropRect.map(String.init(describing:)) ?? "none")
              trim:    \(frameRange.map { "\($0.lowerBound)..<\($0.upperBound)" } ?? "full")

            """.utf8))
        }

        do {
            let pipeline = try CoreEncoder.makePipeline(request, audio: audioData)
            try await pipeline.run()
        } catch {
            // Partial output after a mid-stream throw is a corrupt
            // ftyp/wide/mdat-no-moov file (the writer's finish() never ran).
            // Remove it so a failed run leaves nothing misleading on disk.
            try? FileManager.default.removeItem(at: outputURL)
            FileHandle.standardError.write(Data("error: encode failed: \(error)\n".utf8))
            throw ExitCode.failure
        }

        // Success path: print the output path to stdout (machine-readable).
        print(outputURL.path)
    }

    // MARK: - Argument parsing

    static func parseCodec(_ s: String) throws -> OutputCodec {
        let key = s.lowercased()
        if let f = DXVFormat(rawValue: key) {
            return .dxv(f)
        }
        switch key {
        case "prores422":      return .prores(.proRes422)
        case "prores422hq":    return .prores(.proRes422HQ)
        case "prores422lt":    return .prores(.proRes422LT)
        case "prores422proxy": return .prores(.proRes422Proxy)
        case "prores4444":     return .prores(.proRes4444)
        case "h264":           return .h264
        case "hevc":           return .hevc
        case "mjpeg":          return .mjpeg
        default:
            throw ValidationError("""
            unknown --codec: \(s)
            valid: dxt1 dxt5 ycg6 yg10 hap1 hap5 hapy hapa hapm \
            prores422 prores422hq prores422lt prores422proxy prores4444 h264 hevc mjpeg
            """)
        }
    }

    static func parseContainer(_ s: String, codec: OutputCodec) throws -> OutputContainer {
        guard let c = OutputContainer(rawValue: s.lowercased()) else {
            throw ValidationError("invalid --container: \(s) (mov|mp4)")
        }
        guard codec.allowedContainers.contains(c) else {
            throw ValidationError("container \(c.rawValue) is not allowed for \(codec) (allowed: \(codec.allowedContainers.map(\.rawValue).joined(separator: ", ")))")
        }
        return c
    }

    static func parseOutputSize(width: Int?, height: Int?) throws -> OutputSize {
        switch (width, height) {
        case (nil, nil):
            return .original
        case let (w?, h?):
            guard w > 0, h > 0 else {
                throw ValidationError("--width/--height must be positive")
            }
            return .custom(width: w, height: h)
        default:
            throw ValidationError("--width and --height must be given together")
        }
    }

    static func parseCrop(_ s: String) throws -> CGRect {
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 4,
              let x = Int(parts[0]), let y = Int(parts[1]),
              let w = Int(parts[2]), let h = Int(parts[3]) else {
            throw ValidationError("invalid --crop: \(s) (expected x:y:w:h integers)")
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func parseTrim(_ s: String) throws -> Range<Int> {
        let parts = s.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let lo = Int(parts[0]), let hi = Int(parts[1]),
              lo >= 0, hi > lo else {
            throw ValidationError("invalid --trim: \(s) (expected start:end with 0 <= start < end)")
        }
        return lo..<hi
    }
}
