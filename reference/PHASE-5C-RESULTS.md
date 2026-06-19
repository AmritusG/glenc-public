# Phase 5C — Endpoint search refinement experiments

**Date range:** 2026-05-11
**Outcome:** Both refined paths (BC1 ClusterFit, BC4 endpoint-refinement
search) measured against clean-methodology real-content corpora,
found sub-perceptual SSIM regression. Reverted to v0.2.0/v0.3.0/v0.4.0
baseline algorithms for v0.5.0 ship. Refined paths remain in repo as
callable A/B options.

## Why this phase existed

Phase 5B Resolume Arena verdict on YG10 v0.5.0-pre-tag output:

> "YG10, all colors except red lacks saturation. Yellow lack most
> vibrance. Blue is not blue, its blue towards purple tint. Magenta
> lacks saturation. Cyan lacks vibrance."

The hypothesis: BC4 (HQ chroma planes) and/or BC1 (DXT1 / DXT5 color)
endpoint search were producing suboptimal endpoints on saturated
content, eating chroma fidelity. Two refined algorithms were
implemented and measured.

## Phase 5C.1 — Reference implementation study

Studied FFmpeg `texturedspenc.c` (current GlEnc port), Squish
RangeFit / ClusterFit, bc7enc / rgbcx. Picked Squish ClusterFit for
BC1 (4-color path only, BT.709 luma-weighted error), rgbcx-style
endpoint refinement for BC4 (7×7 search grid). Documented in
`reference/endpoint-search-study/FINDINGS.md`.

## Phase 5C.2 — BC1 ClusterFit implementation

Implemented in `Sources/GlEncCore/BC1BlockEncoderClusterFit.swift`
(379 lines). Initial measurement against testsrc2 + the ProRes-chain
ShroomiesKingdom corpus showed +0.0011 SSIM / -0.00053 SSIM split
across DXT1 testsrc2 vs DXT5 ShroomiesKingdom_5s. Phase 5C.2 Arena
visual A/B test (DXT5 alpha-mode pre-cleanup experiment) revealed
the ProRes-chain corpus itself had pre-existing JPG-like artifacts
NOT present in PNG ground truth — testing against it was
methodologically broken.

## Phase 5C.2.5 — Methodology rebuild

Replaced the ProRes-chain real-content corpus with PNG-direct corpora:

- **`reference/synthetic-corpus/`** — 12 controlled stress patterns
  (primaries, secondaries, gradients, alpha edges) generated via
  CoreGraphics, 1920×1080 RGBA, deterministic.
- **`reference/realworld-corpus/`** — 30 PNG frames from
  ShroomiesKingdom_29.mov (turned out to be DXT1, no alpha), 4K
  RGBA, decoded directly via GlanceCore — single-decode-stage real
  content.

`reference/CORPUS-METHODOLOGY.md` documents the methodology and
decode paths.

## Phase 5C.2.6 — YCoCg precision audit

Instrumented `YCoCgTransform` with synthetic primaries, near-primaries
(5-LSB inset), grayscale ramp, and full-plane round-trips. Verdict:
**transform is clean.**

- Grayscale ramp: chroma stays at signed-zero (stored 128) for every
  gray value. Zero rounding bias.
- Pure primaries: ≤1 LSB drift per channel — inherent to non-
  reversible YCoCg at the 8-bit boundary (continuous Co range
  [-127.5, +127.5] cannot map exactly to signed [-128, +127]; one
  half-LSB slot has to go to one side).
- Encoder forward + GlanceCore inverse are matched-pair rounded.

**The Phase 5B desaturation symptom does NOT live in the YCoCg
transform.**

## Phase 5C.3 — BC4 endpoint refinement implementation

Implemented in `Sources/GlEncCore/BC4AlphaBlockEncoderRefined.swift`
(203 lines). rgbcx-style 7×7 endpoint refinement: for each (lo_delta,
hi_delta) ∈ [-3..+3]² around the initial (min, max) endpoints, build
both 8-mode and 6-mode palettes, fit each of 16 source values, pick
the (mode, endpoints) tuple with lowest squared error.

Initial measurement against synthetic + DXT1-only corpora showed
+0.000012 SSIM gain on YCG6 testsrc2 — **80× below the 0.001
threshold the planner set for "useful improvement."** Diagnosis: the
test corpora didn't exercise non-constant BC4 chroma blocks at
scale (testsrc2 has wide flat stripes that hit BC4's constant-block
fast path; ShroomiesKingdom_29 is DXT1-only with α=255 throughout).

Built Phase 5C.3.5 to address the corpus gap.

## Phase 5C.3.5 — Real-content HQ corpus

Built paired DXT5 + YG10 corpora from
`ShroomiesKingdom_05_DXV {Normal,High} Quality With Alpha.mov`
(both 3840×2160, 300 frames, 30 fps, paired by source content):

- **`reference/realworld-yg10-corpus/`** — 30 PNG frames, YG10 source
  decoded via `DXVHQDecoder.decompressYG10` + `CPURender.cgImageFromHQ`,
  116.6 MB total.
- **`reference/realworld-dxt5-paired-corpus/`** — same source moments
  decoded from the paired DXT5 file via `DXVPacketDecoder.decompressDXT5` +
  `CPURender.cgImageFromDXT`, 112.8 MB total.

Content: saturated cyan / orange / yellow flame circles on transparent
black — the BC4-chroma-stressing real material synthetic +
DXT1 corpora lacked.

Window choice: frames 65..94 (densest 30-frame packet-size window in
the YG10 file). Both corpora frame-aligned by construction.

## Phase 5C.4 — BC4 refined measurement on real HQ content

A/B test on both real-content corpora.

| Corpus | refined OFF | refined ON | Δ SSIM |
|---|---|---|---|
| DXT5 paired (4K) | 0.868529 | 0.868529 | 0.000000 |
| **YG10 (4K)** | **0.999786** | **0.999662** | **-0.000124** |

Per-channel mean LSB Δ vs source PNG (YG10):

| | R | G | B | α |
|---|---|---|---|---|
| OFF | 0.100 | 0.047 | 0.095 | 0.011 |
| ON  | 0.136 | 0.090 | 0.127 | 0.047 |
| Δ   | +0.036 | +0.043 | +0.033 | +0.035 |

Per-channel regression is **symmetric across R/G/B/α** — no pattern
matching Phase 5B's "all colors except red lack saturation" symptom.

Wall-clock: DXT5 +18 %, **YG10 +190 % (3×)**.

### Bonus: YG10 vs DXT5 quality on same source

Same source moments, two encoder variants:

| Variant | mean SSIM | meanΔR | meanΔG | meanΔB |
|---|---|---|---|---|
| YG10 | 0.999662 | 0.136 | 0.090 | 0.127 |
| DXT5 | 0.868529 | 21.536 | 20.652 | 12.805 |

**SSIM gap 0.131; mean RGB Δ ratio ~160×.** The strongest evidence
to date that HQ buys real-content quality over Normal for saturated
alpha-bearing VJ content. BC1's RGB565 quantization is brutal on
saturated chroma; YG10's YCoCg + half-res chroma + BC4 preserves the
same content nearly intact. **This justifies the YG10 path's
existence by itself.**

**Verdict: refined BC4 sub-perceptual regression on real content.
Revert default.**

## Phase 5C.4.5 — BC1 ClusterFit measurement on real content

A/B test on DXT1 ShroomiesKingdom_29 (4K, no alpha) and DXT5 paired
(4K, alpha-bearing).

| Corpus | BC1 FFmpeg | BC1 ClusterFit | Δ SSIM |
|---|---|---|---|
| **DXT1 ShroomiesKingdom_29** | 0.999247 | 0.998476 | **-0.000771** |
| **DXT5 paired** | 0.869082 | 0.868529 | **-0.000553** |

Per-channel mean LSB Δ vs source PNG:

| Corpus | path | ΔR | ΔG | ΔB | Δα |
|---|---|---|---|---|---|
| DXT1 | FFmpeg  | 0.076 | 0.065 | 0.102 | 0.000 |
| DXT1 | Cluster | 0.049 | 0.043 | 0.038 | 0.000 |
| DXT1 | diff    | **-0.027** | **-0.022** | **-0.064** | 0 |
| DXT5 | FFmpeg  | 21.552 | 20.720 | 12.852 | 0.011 |
| DXT5 | Cluster | 21.536 | 20.652 | 12.805 | 0.011 |
| DXT5 | diff    | -0.016 | -0.068 | -0.047 | 0 |

**ClusterFit improves per-pixel mean LSB Δ but regresses SSIM** — the
classic SSE-vs-perceptual mismatch. ClusterFit minimizes its design
objective (per-pixel squared error, which goes down). SSIM measures
local mean / variance / covariance structure, which the FFmpeg path
preserves slightly better via "endpoints picked from actual block
pixels" rather than from LS-optimal grid points.

Wall-clock: DXT1 12×, DXT5 4×.

**Verdict: revert default. ClusterFit remains callable.**

## Combined conclusion

Phase 5C ruled out three encoder-side causes for the Phase 5B Arena
desaturation symptom:

1. **YCoCg transform precision** (5C.2.6: clean).
2. **BC4 endpoint search** (5C.4: refinement sub-perceptual / slight
   regression).
3. **BC1 endpoint search** (5C.4.5: refinement sub-perceptual /
   slight regression).

The encoder is doing its job on the metrics we can measure
programmatically. The Phase 5B Arena symptom must live downstream —
most likely in Arena's render pipeline (decode → composite → display
path), specifically how it handles chroma upsample on premultiplied
YG10 content. Resolving this is **out of GlEnc scope**; it would be
a Glance / Arena pipeline investigation.

## Phase 5C.6 — Arena re-verification verdict

User compared the v0.5.0 candidate against source PNG ground truth +
Alley + AME references in Resolume Arena. Verdict per variant:

- **DXT1**: Alley and AME identical, bit low on green. **GlEnc and
  source indistinguishable.**
- **DXT5**: Alley bit low on green. AME significant dip in yellow +
  blue. **GlEnc and source indistinguishable.**
- **YCG6**: Alley and AME identical, bit low on green. **GlEnc and
  source indistinguishable.**
- **YG10**: Alley too bright vs source. AME close match, bit low on
  green. **GlEnc and source indistinguishable.**

GlEnc matches source ground truth on all four variants. Both reference
encoders carry small biases vs source; GlEnc doesn't.

## Reframing finding: Phase 5B was a reference-misread

The Phase 5B Arena observation that triggered the entire Phase 5C
investigation — *"YG10 all colors except red lack saturation, yellow
lacks vibrance, blue tints purple, magenta desaturates, cyan loses
vibrance"* — was an accurate eye-perception, **but compared against
Alley's YG10**, the visually-most-saturated reference encoder. The
Phase 5C.6 verdict reveals **Alley's YG10 is "too bright vs source"**
— Alley over-saturates, not GlEnc under-saturates.

The encoder was already correct in Phase 5A. The Phase 5C
investigation chain — BC1 ClusterFit, BC4 endpoint refinement, YCoCg
audit, real-content corpus rebuild, measurement A/Bs, default flips —
was triggered by a **measurement-reference confusion** that source-
PNG ground truth resolved.

**Future quality work lesson:** reach for source PNG as the gate,
not other encoders. The Phase 5C.2.5 methodology rebuild
(`reference/CORPUS-METHODOLOGY.md`) bakes this lesson into the
project — PNG-direct corpora are the reference; encoders are
artifacts to measure, not standards to match.

## Value the Phase 5C work produced anyway

Even though the trigger was a misread, Phase 5C produced substantive
deliverables that outlast this phase's specific findings:

- **PNG-direct corpus methodology** (5C.2.5). Replaced the Phase
  3B/4B/5B ProRes-chain corpus that carried pre-existing JPG-like
  artifacts not present in source PNGs. All future encoder
  measurements use this clean methodology.
- **YCoCg precision audit** (5C.2.6). Formally verified the forward
  transform is clean — grayscale produces zero chroma exactly,
  primaries round-trip ≤ 1 LSB (inherent to non-reversible YCoCg at
  the 8-bit boundary). Encoder/decoder rounding pair is matched.
  `Tests/GlEncTests/YCoCgPrecisionAuditTests.swift` is reusable
  regression coverage.
- **Two refined-algorithm implementations preserved as callable A/B
  options** (5C.2 + 5C.3). `BC1BlockEncoderClusterFit.swift` (379
  lines) and `BC4AlphaBlockEncoderRefined.swift` (203 lines) remain
  in the repository, default-off, callable via `BC1Config` and
  `BC4Config` flags. Future quality work on different content types
  may re-test against the existing corpora without re-implementing.
- **Paired DXT5/YG10 real-content corpus** (5C.3.5).
  `reference/realworld-yg10-corpus/` and
  `reference/realworld-dxt5-paired-corpus/` — 30 PNG frames each at
  4K from ShroomiesKingdom_05 paired source. Future measurement
  against this corpus exercises non-constant BC4 chroma blocks at
  scale.
- **Headline measurement for v0.5.0**:
  **SSIM 0.999662 (YG10) vs 0.868529 (DXT5)** on identical 4K alpha-
  bearing source content. **160× mean RGB LSB delta ratio.** This is
  the strongest empirical evidence yet that HQ buys real-content
  quality over Normal for saturated alpha-bearing VJ content — the
  variant that matters most for the encoder's target use case.

## What ships in v0.5.0

| Variant | Algorithm | Notes |
|---|---|---|
| DXT1 | v0.2.0 FFmpeg-port BC1 | `BC1Config.useClusterFit = false` |
| DXT5 | v0.3.0 baseline | BC1 + simple BC4, both unchanged |
| YCG6 | v0.4.0 baseline | BC4 simple, YCoCg unchanged |
| **YG10** | **Phase 5A new** | Composition of HQ machinery + alpha plane + premultiplied alpha-mode per Pass D |

**All four DXV3 variants now ship.** The encoder family is feature-
complete. v0.5.0 is squarely "YG10 lands, completing the family"
with the BC1/BC4 quality work cleanly scoped out as "experiments
that didn't move the needle on real content; refined paths
available for future investigation."

## Refined paths preserved

Both refined-algorithm implementations remain in the repository:

- `Sources/GlEncCore/BC1BlockEncoderClusterFit.swift` — Squish-style
  ClusterFit. Callable via `BC1Config.useClusterFit = true`.
- `Sources/GlEncCore/BC4AlphaBlockEncoderRefined.swift` — rgbcx-style
  endpoint refinement. Callable via `BC4Config.useRefinement = true`.
- Both off by default.

Future quality work or different content types may make either
worthwhile to re-activate without re-implementing. The Phase 5C
measurement methodology (real-content corpora + SSIM-vs-source
matched-pair A/B) is the template for any such re-evaluation.

## Cross-references

- `reference/endpoint-search-study/FINDINGS.md` — Phase 5C.1
  algorithm survey.
- `reference/CORPUS-METHODOLOGY.md` — corpus methodology rebuild.
- `Tests/GlEncTests/CorpusGenerationTests.swift` — corpus generators.
- `Tests/GlEncTests/YCoCgPrecisionAuditTests.swift` — transform audit.
- `Tests/GlEncTests/Phase5C4MeasurementTests.swift` — refined-BC4 +
  ClusterFit-BC1 measurements (gated by
  `GLENC_RUN_5C4_MEASUREMENT=1` / `GLENC_RUN_5C45_MEASUREMENT=1`).
