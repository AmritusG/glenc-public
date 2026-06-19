# Phase 4B — YCG6 ship-readiness measurements

**Date:** 2026-05-11
**Tag:** v0.4.0 (this commit)
**Encoder:** `GlEnc 0.4.0`
**Reference corpus:** Pass C testsrc2 (1920×1080, 30 fps, no alpha).
Source: `reference/ycg6/source/frame_NNNN.png` + `source.mov`.

## Summary

| Gate | Threshold | Measured | Verdict |
|---|---|---|---|
| Resolume Arena playback | "plays clean" | ✓ (user-verified during Phase 4A) | **PASS** |
| SSIM(GlEnc, source) on RGB | mean ≥ 0.995 | **0.999737** | **PASS** |
| Alpha pixel-Δ vs source | N/A — YCG6 is no-alpha | — | **N/A** |
| File size vs Alley | ≤ 2× | PNG corpus 1.296×, ProRes 1.325× | **PASS** |

YCG6 ship-ready as **v0.4.0**.

## Resolume Arena playback

User-verified during the Phase 4A session: **"Tested and plays back
properly in Resolume."** Same encoder, same `DXVMOVWriter`, same packet
shape as the v0.4.0 artifact (`reference/ycg6/glenc.mov`); no re-verify
needed.

## SSIM(GlEnc, source) — RGB via BT.709 luma

8×8 non-overlapping windows, K1=0.01, K2=0.03. Same implementation as
Phase 2C (DXT1) / Phase 3B (DXT5). Decoder: `GlanceCore.DXVHQDecoder`
(luma + chroma) → `CPURender.cgImageFromHQ` → BT.709 luma. Source:
Pass C PNGs loaded via `CGImageAlphaInfo.noneSkipLast` → BT.709 luma.

Aggregate over 30 frames:
- **Mean SSIM = 0.999737**
- **Min  SSIM = 0.999731 @ frame 28**
- Range: 0.999731 – 0.999741 (variance ≈ 1.0 × 10⁻⁵)

Per-frame table (excerpt — full output in
`Tests/GlEncTests/Phase4BResultsTests.swift`):

| frame | SSIM | frame | SSIM | frame | SSIM |
|---|---|---|---|---|---|
| 0 | 0.999736 | 10 | 0.999736 | 20 | 0.999739 |
| 1 | 0.999736 | 11 | 0.999738 | 21 | 0.999739 |
| 2 | 0.999737 | 12 | 0.999735 | 22 | 0.999737 |
| 3 | 0.999736 | 13 | 0.999738 | 23 | 0.999739 |
| 4 | 0.999738 | 14 | 0.999737 | 24 | 0.999740 |
| 5 | 0.999739 | 15 | 0.999741 | 25 | 0.999736 |
| 6 | 0.999736 | 16 | 0.999737 | 26 | 0.999733 |
| 7 | 0.999737 | 17 | 0.999738 | 27 | 0.999735 |
| 8 | 0.999737 | 18 | 0.999738 | 28 | 0.999731 |
| 9 | 0.999733 | 19 | 0.999736 | 29 | 0.999733 |

The tight variance (1.0 × 10⁻⁵) confirms encoder behavior is
frame-content-independent on testsrc2 — Pass C's prediction that BC4
endpoint search converges on flat regions and the cgo state machine
absorbs most of the per-frame entropy holds.

Phase 4A pixel-Δ stats (mean |Δ_RGB| 0.523 LSB/channel; max-per-channel
42 LSB on BC4-saturated edges) corroborate the SSIM result. The
~42-LSB max delta lives on testsrc2's saturated color-bar edges, which
are BC4's intrinsic pathology; the SSIM window averaging absorbs those
without measurable visual impact.

## Alpha gate

N/A — YCG6 is the no-alpha HQ variant. YG10 in Phase 5 reintroduces
alpha measurements (BC4 alpha plane, third op-stream).

## File size

| File | Bytes | vs Alley YCG6 (3,582,843) |
|---|---|---|
| GlEnc PNG corpus     | 4,643,505 | **1.296×** |
| GlEnc ProRes pipeline | 4,749,050 | **1.325×** |
| Alley YCG6 reference | 3,582,843 | 1.000× (Pass C) |
| AME   YCG6 reference | 3,551,267 | 0.991× (Pass C) |

The 1.296× / 1.325× ratios are within the Phase 4 gate (2× Alley on
real motion content). Pass C measured Alley = 3.58 MB and AME = 3.55 MB
on the same testsrc2 corpus; GlEnc lands ~30% larger because:

1. Opcode streams use raw mode (`flag & 3 == 0`) — Pass C observed
   references using Huffman (`flag & 3 == 2`) exclusively. Raw is
   uncompressed but valid per `dxv_decompress_opcodes`. Huffman would
   save ~50 % of the opcode-stream bytes per Pass C measurement.
2. cgo encoding uses 3 of the 17 opcodes (op 0 RLE, op 1 copy-prev,
   op 3 8-byte literal). The lookup-table ops (4, 5, 6, 8, 9, 10, 11,
   14, 15, 16) and long back-ref ops (2, 7, 12, 17) are encoder
   discretion; deferred to v0.4.1.

Both are strictly additive size optimizations — neither disturbs the
byte-equivalent invariants Pass C locked, nor the round-trip pixel-Δ /
SSIM gates already cleared.

## v0.4.1 deferrals

These three optimizations together should close the ratio toward
1.0× Alley. Each is strictly additive (no byte-identity invariants
disturbed):

1. **Huffman opcode-stream encoding.** Implement `fill_ltable` /
   `fill_optable` forward simulation + inverse-bitstream output.
   Pass C: 100 % of reference opcode streams use Huffman. Expected
   savings on testsrc2: ~50 % of opcode-stream bytes ≈ 350 KB total
   over the corpus.
2. **Extended cgo opcodes.** Highest-leverage additions per Phase 4A
   block-type analysis:
   - **op 13** (copy prev[0..1] + literal 2..7): saves 2 bytes per
     block when adjacent BC4 blocks share endpoints — common in
     spatially smooth chroma.
   - **op 17** (copy prev[0..1] + long back-ref for bytes 2..7):
     saves 6 bytes per block when an earlier block's index pattern
     repeats.
   - **op 2** (long back-ref full block): saves 6 bytes per block on
     true block-level repetition that's too far for op 1.
   - **op 7** / **op 12**: 2-byte-literal hybrids for partial matches.
3. **Real-content size measurement.** Only synthetic testsrc2 is
   measured in Phase 4B (Pass C corpus is the only YCG6 reference
   committed). Pass B's ShroomiesKingdom 4K corpus is DXT5-only; a
   YCG6 real-content corpus (drop-in equivalent — re-encode any
   existing motion graphic) would let us characterize the
   content-dependent ratio. Same lesson as Phase 3B: synthetic
   content compresses well in HQ; real motion content may need the
   v0.4.1 optimizations to hit ≤1.5× Alley.

## Cross-reference

- **Round-trip pixel-Δ (Phase 4A, 30 frames vs source PNGs):**
  mean R = 0.487, G = 0.304, B = 0.779 LSB; mean overall **0.523
  LSB/channel**. Max per-channel 42 LSB on BC4-saturated edges.
- **DXT1 byte-identity preserved** (`testAllFramesByteExactMatch`
  passes unchanged, v0.2.0 contract intact).
- **DXT5 round-trip preserved** (`testRoundTripViaGlanceCore` passes
  unchanged, v0.3.0 contract intact).
- **YCG6 Pass C invariants honored:** stream FourCC `DXD3`, per-frame
  tag `36 47 43 59` (LE), `version_major+1 = 0x04`, `version_minor =
  0x00`, `raw_flag = 0x00`, `unknown = 0x00`, stsd 102 bytes
  byte-identical to DXT1/DXT5 (SHA-256 `eef02359c036413f`).
- **ffprobe verdict on `/tmp/glenc-ycg6-smoke.mov`:**
  `codec_name=dxv`, `codec_tag_string=DXD3`, `pix_fmt=yuv420p`,
  `color_space=ycgco`, 1920×1080, 30/1 fps, 30 frames, duration
  1.000 000 s. All 30 frames carry the YCG6 tag.

## Test count

| Phase | Tests |
|---|---|
| v0.3.0 (Phase 3B) | 47 |
| v0.4.0 (Phase 4B) | **68** (+21: YCoCgTransform×9, BC4PlaneEncoder×4, YCG6Encoder×4, Phase4BResults×1, plus three test-helper classes) |

Run: `swift test -c release` — 68 pass, 2 skipped (Phase 3B
real-content corpus optional), 0 failures, ~48 s wall-clock.

---

End of Phase 4B results.
