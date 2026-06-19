# Endpoint search study — Phase 5C.1

**Date:** 2026-05-11
**Status:** research only — no code changes. Deliverable is this document.

## Why this study exists

Phase 5B Resolume Arena comparison surfaced a visible color-fidelity gap
between current GlEnc and source/Alley on saturated content:

- **YG10 vs source:** GlEnc's cyan and green came out distinctly less
  saturated than AME's YG10 of the same source. Likely cause: BC4 chroma
  (Co/Cg) endpoint search picking endpoints from extreme pixels in
  mostly-flat blocks with anti-aliased trace lines.
- **DXT5 vs source/Alley:** GlEnc's straight-RGB DXT5 matches source and
  Alley well (verified in Phase 5B pre-cleanup A/B). BC1 endpoint search
  failures haven't been observed on DXT5 yet, but the failure mode
  (PCA-extreme picks polluted by outlier pixels) is structurally
  identical for BC1 and BC4 and will eventually surface on richer
  content.

Project decision:
> **v0.5.0 holds until improved BC1/BC4 endpoint search lands.** The
> v0.2.0 byte-identity-to-ffmpeg contract is intentionally retired in
> v0.5.0 — new contract is fidelity-to-source. v0.5.0 ships YG10 + all
> four variants under the improved encoder.

This document surveys the BC1/BC4 algorithm landscape and recommends
what to port (or write from spec) in Phases 5C.2 and 5C.3.

---

## Current state — what GlEnc does today

### BC1 — `Sources/GlEncCore/BC1BlockEncoder.swift` (Phase 2A)

Faithful Swift port of FFmpeg's `libavcodec/texturedspenc.c`
(MIT-licensed, Vittorio Giovara 2015, based on public-domain code by
Fabian Giesen / Sean Barrett / Yann Collet). Per block:

1. **Constant-color fast path.** If all 16 pixels are byte-identical,
   look up the optimal RGB565 endpoint pair via the `match5` / `match6`
   tables. Mask = `0xAAAAAAAA` (all pixels select palette index 2, the
   2:1 lerp position).

2. **`optimize_colors()` — PCA + power iteration.**
   - Compute per-channel min / max / mean over 16 pixels.
   - Build 3×3 covariance matrix on (r-µ, g-µ, b-µ).
   - 4 iterations of power iteration to find the dominant eigenvector
     of the covariance matrix. Initial vector = (max-min) per channel.
     Falls back to JPEG luma weights (299, 587, 114) when the axis
     magnitude is too small (< 4.0).
   - Project all 16 block pixels onto that axis; pick the pixels at
     the extreme projections as endpoint candidates.
   - Quantize those two pixels into RGB565 endpoints via the `bc1Mul8`
     8-bit-emulation helper.

3. **`match_colors()`** — project pixels onto the (c0..c1) line,
   bucket into 4 palette indices based on which third of the line
   each falls in. Returns the 32-bit index mask.

4. **`refine_colors()` — single least-squares refinement pass.**
   Given current indices, solve for the (a, b) endpoint pair that
   minimizes total squared error under the current cluster
   assignment. Uses the `prods[]` accumulator-weight magic constants.
   Singular-system fallback: if all 16 indices coincide, set
   endpoints to the block average.

5. **Re-match if endpoints changed.** One pass only (FFmpeg does
   one pass total; not iterated).

6. **Force 4-color mode.** If `max16 < min16`, swap endpoints and
   XOR mask by `0x55555555` to flip index parity.

Complexity: ~16 × constant per block. Fast. Float-math FMA contraction
order matched against clang -O2 of the C reference for byte-identity
(see `feedback_fma_byte_identity.md`).

**Failure mode hypothesis (Phase 5B observation).** Endpoints are
picked **from actual block pixels at extreme projections.** When a
block is mostly a saturated color (say cyan at (0, 255, 255)) with a
few anti-aliased trace-line or sub-pixel-edge pixels, those few
outliers dominate the PCA axis — minp/maxp can land on the outliers
rather than on the saturated bulk. The endpoint pair is then biased
toward the outliers, palette index 2 / 3 (1/3 and 2/3 lerps) lands
inside the bulk pixel cloud at a *desaturated* point, and the
reconstructed saturated pixels are visibly less saturated than the
source. Refine helps but only nudges from the bad starting position
in a single pass.

### BC4 — `Sources/GlEncCore/BC4AlphaBlockEncoder.swift` (Phase 3A)

Written from spec, no FFmpeg port. Per block:

1. Scan 16 pixels for min and max.
2. **Constant-value fast path.** If min == max, write the trivial
   block.
3. **8-mode candidate:** endpoints = (max, min), full palette is
   max / min plus 6 interpolated values between.
4. **6-mode candidate:** endpoints = (min2, max2) where min2/max2
   exclude any 0/255 pixels (those are encoded via reserved palette
   slots 6=0, 7=255). Falls back to (0, 255) if all pixels are 0/255.
5. For each candidate: closest-palette-index fit on all 16 pixels,
   accumulate absolute error.
6. Lower-error mode wins.

Complexity: 16 × 8 palette-distance comparisons, twice (modes 6 + 8),
plus 2 × palette computations. Trivially fast.

**Failure mode hypothesis.** Same structural issue as BC1. Endpoints
are picked from actual block pixel min/max. A mostly-flat chroma
block (e.g. Co plane region for solid cyan) with a few outlier
samples (from anti-aliased edges, BT.709 source-pipeline shifts, or
chroma subsample averaging on transitions) gets its endpoints
**pulled toward those outliers**, and the bulk pixels land on
imperfect interpolated palette positions. The visible effect on
chroma planes after YCoCg + half-res subsample + BC4 quantization is
the desaturated cyan / green Phase 5B reported in Arena.

---

## FFmpeg `texturedspenc.c`

Already described above as GlEnc's current source. Recap as a
comparison baseline:

- **Algorithm:** PCA / power iteration → endpoints from block pixels
  at axis extremes → 1× match → 1× LS refine → 1× re-match.
- **Endpoint quantization:** via `bc1Mul8` 8-bit-emulation
  mul (mimics 5/6-bit GPU hardware quantization).
- **Error metric:** implicit (uniform L2 in linear RGB during PCA;
  1D projection distance in match_colors).
- **3-color BC1 variant:** not used — `texturedspenc.c` forces 4-color
  mode (good — DXV3 doesn't use 3-color either).
- **Complexity:** O(16) per block dominant. ~85s for 30 frames at
  1920×1080 in GlEnc's current release build.
- **License:** MIT (file header).
- **Strengths:** byte-identical to `ffmpeg -c:v dxv -format dxt1`, the
  v0.2.0 development contract. Fast.
- **Known failure mode:** outlier-dominated PCA on mostly-flat
  saturated blocks (Phase 5B Arena finding).

---

## Squish (libsquish, MIT, Simon Brown 2006 / Ignacio Castano 2007)

`/tmp/glenc-recon/squish/libsquish-master/`. Two BC1 algorithms:

### Squish RangeFit (`rangefit.cpp`)

Same idea as FFmpeg but with a couple of refinements:

- PCA via `ComputePrincipleComponent` (`maths.cpp` — covariance +
  power iteration, same as FFmpeg).
- **Endpoints picked from clamped + grid-quantized projections of
  the extreme pixels** rather than the pixels themselves. Clamps to
  [0, 1] before snapping to the RGB565 grid (31, 63, 31). Avoids
  out-of-range endpoint candidates.
- **Configurable perceptual metric.** `m_metric` is a 3-vector of
  per-channel error weights (Squish documents "old perceptual" =
  (0.2126, 0.7152, 0.0722) which are BT.709 luma coefs). Default is
  (1, 1, 1) i.e. uniform L2. The metric is applied to the Euclidean
  distance during palette matching, not just projection.
- **Match metric:** `LengthSquared(metric * (pixel - code))` —
  3D Euclidean (not 1D projection). This finds the truly closest
  palette entry per pixel rather than the closest position along the
  endpoint line.

Complexity: O(16) per block + small constant for PCA. Roughly
comparable to FFmpeg's path; slightly more bookkeeping.

### Squish ClusterFit (`clusterfit.cpp`) — the high-quality variant

**This is the algorithm that addresses the Phase 5B failure mode.**

Setup:
1. PCA → principal axis.
2. **Sort all 16 pixels along the axis** (`ConstructOrdering`).

Then for 4-color mode (`Compress4`):
- **Triple-nested loop over all valid 4-cluster partitions** of the
  sorted-pixel sequence: outer i, middle j, inner k partition pixels
  into clusters [0..i), [i..j), [j..k), [k..count).
- For each partition, **directly compute the least-squares-optimal
  (a, b) endpoint pair** that minimizes total squared error given
  that cluster assignment. The math is closed-form: alpha2_sum,
  beta2_sum, alphabeta_sum are accumulated from the cluster
  positions; factor = reciprocal of (alpha2 * beta2 - alphabeta²);
  a, b solved via cross-products.
- Clamp (a, b) to [0, 1], snap to the RGB565 grid.
- Compute residual error under the optimal endpoints.
- Track the (i, j, k, a, b) tuple with the lowest error.

After the partition sweep, optionally **iterate**: take the winning
(a, b) endpoints, re-sort pixels along the new axis (b - a), and
sweep partitions again. Stops when a sweep doesn't improve or the
ordering repeats (deduped via `m_order` table) or `kMaxIterations`
reached.

Complexity: O(count³) = O(4096) partition evaluations per block per
ordering iteration. Famously slower than RangeFit but well-known to
produce the highest BC1 quality of any analytical algorithm.

**Why this fixes the Phase 5B failure mode.** The endpoints come from
**closed-form least-squares solutions over cluster partitions**, not
from individual pixels. The "outlier-dominated PCA" failure mode of
FFmpeg's algorithm doesn't apply — outliers may shift the partition
boundary by one or two pixels, but the LS-optimal endpoint pair for
the bulk cluster is still on the saturated color line because the
bulk cluster's least-squares fit doesn't care about a couple of
outlier pixels in another cluster.

License: MIT (Simon Brown / Ignacio Castano).

### Squish BC4 (`alpha.cpp` `CompressAlphaDxt5`)

Algorithm identical in shape to GlEnc's current BC4:
1. Pick min/max for each of the 5-mode (excluding 0/255) and 7-mode
   (including 0/255).
2. **`FixRange(min, max, steps)`** — ensures the range is at least
   `steps` wide so the palette has meaningful interpolation. Subtle
   knob GlEnc currently lacks.
3. Build both codebooks, compute total error against the 16 pixels
   via `FitCodes` (the same closest-index loop).
4. Lower-error mode wins.

So Squish's BC4 is structurally identical to GlEnc's — same min/max
picks, same two-mode try, same closest-index fit. The only quality
delta is `FixRange`. **Squish doesn't have a higher-quality BC4
search.** Squish's quality reputation is for BC1, not BC4.

---

## bc7enc / rgbcx (Rich Geldreich, MIT or Public Domain)

`/tmp/glenc-recon/bc7enc_rdo-master/rgbcx.{h,cpp}`. Modern fast
encoder for BC1-5; the `rgbcx` module is the BC1/3/4/5 portion (BC7 is
separate). 19 quality levels exposed via `encode_bc1(level, ...)`.

### rgbcx BC1

Same algorithm family as Squish ClusterFit but with two important
engineering choices:

- **Pre-computed "likely total orderings" tables.** Instead of
  evaluating all O(count³) partitions per block, rgbcx ships
  histograms of which orderings are statistically most common and
  evaluates the top-N (configurable: `total_orderings4` ranges 1..128
  depending on level). At level 10 the default is 20 orderings,
  yielding "3× faster than libsquish at slightly higher average
  quality" (README).
- **Two least-squares passes** (`cEncodeBC1TwoLeastSquaresPasses`):
  one LS pass to refine after the partition sweep, then re-match and
  do another LS pass. FFmpeg does 1 pass total; this gives an extra
  refinement step.
- **6 power-iterations** option (`cEncodeBC1Use6PowerIters`) — FFmpeg
  does 4; 6 converges the eigenvector slightly more accurately.
- **Bounding-box / 2D-LS / iterative / exhaustive** options on the
  high levels.

Level mapping (from `rgbcx.cpp`):
- Levels 0–4: compete against `stb_dxt`.
- Level 5+: compete against Squish / NVTT / icbc.
- Level 10 default: TwoLeastSquaresPasses + UseLikelyTotalOrderings
  with 20 orderings.
- Level 18: TwoLeastSquaresPasses + FullMSEEval + Use6PowerIters +
  Iterative + 256 endpoint search rounds + all initial endpoints,
  with `MAX_TOTAL_ORDERINGS4` = 128 orderings.

Complexity: tunable. Level 10 ≈ 3× faster than Squish ClusterFit at
single iteration. Level 18 ≈ 10–100× slower than level 10.

### rgbcx BC4

`encode_bc4(fast)` matches Squish/GlEnc shape. `encode_bc4_hq` adds:

- **Endpoint refinement search** around initial min/max picks. For
  each (mode_8_a, mode_8_b) ∈ (init_max ± search_rad, init_min ±
  search_rad), evaluate reconstruction error and keep the best.
  Default `search_rad = 3` → 7 × 7 = 49 candidate pairs per mode.
- Tries both interpolation modes (BC4_USE_MODE6_FLAG and
  BC4_USE_MODE8_FLAG).
- Optionally accepts pre-computed forced selectors for advanced
  optimizations (irrelevant for our use).

Complexity: ~49 × 16 closest-index computations per block per mode ≈
1.6 K palette evaluations per block. Still very fast (~50–100× the
work of GlEnc's current BC4, which is itself trivial).

**This is the BC4 quality upgrade we need.** A small search around
the initial min/max picks directly addresses the "outlier-pulled
endpoints" failure mode on chroma planes.

License: MIT or Public Domain (dual-license, picker's choice).

---

## Quality / speed ranking (qualitative)

For BC1 on photographic / saturated-with-edges content:

1. **rgbcx levels 13–18** — highest quality. Iterative
   ClusterFit + likely-orderings + 2-LS-passes + 6-power-iters +
   endpoint search. Slowest.
2. **Squish ClusterFit (iterative)** — comparable quality, slower
   than rgbcx 10.
3. **Squish ClusterFit (single iteration)** — high quality, ~3×
   slower than rgbcx 10, ~10× slower than FFmpeg.
4. **rgbcx level 10 (default)** — high quality, ~3× faster than
   Squish ClusterFit. Strong "best bang-for-buck" sweet spot.
5. **Squish RangeFit** — slightly better than FFmpeg on saturated
   content (grid-quantized endpoints, perceptual metric option). 1–2×
   FFmpeg speed.
6. **FFmpeg PCA + 1× refine (current GlEnc)** — fast, fails the
   Phase 5B Arena gate on saturated content.

For BC4:

1. **rgbcx `encode_bc4_hq` with search_rad=3** — best quality, ~50×
   slower than baseline.
2. **GlEnc current BC4 / Squish BC4** — identical algorithm shape,
   fast, fails on chroma planes with edge content.

---

## Recommendation for Phase 5C.2 — BC1 endpoint search

**Port Squish ClusterFit (single-iteration variant).**

Reasoning:

1. **Directly fixes the Phase 5B failure mode.** Endpoints are
   least-squares-optimal under cluster partitioning, not picked from
   pixels. Outlier pixels can't pull the endpoints away from the
   saturated bulk color.
2. **Clean reference implementation.** Squish's `clusterfit.cpp` is
   ~400 lines of well-commented C++. The algorithm is a closed-form
   triple-loop with no hidden state. Straightforward Swift port.
3. **Algorithm not copyrightable.** MIT-licensed reference; we credit
   Simon Brown / Ignacio Castano in source comments, write a clean
   Swift implementation. Same lineage as Phase 2A's port of
   `texturedspenc.c`.
4. **Speed cost is acceptable for an offline encoder.** O(16³) = 4K
   partition evaluations per block. At Phase 4B's ~85s for 30 frames
   in current FFmpeg path, ClusterFit at single iteration should land
   around 8–15 minutes for the same corpus — well within "I press
   encode and walk away" territory.
5. **Configurable perceptual metric.** Squish exposes (R, G, B)
   weights — we can pick (0.2126, 0.7152, 0.0722) BT.709 luma to
   bias error toward green, the channel humans see most. Reusable
   across DXT1, DXT5 BC1 color block, and (with adjustment) BC4.
6. **No 3-color path needed.** DXV3 BC1 is 4-color only (Pass A
   invariant). Implementing only `Compress4` keeps the port small.

Estimated implementation effort: **4–8 hours**. ~300–500 lines of
Swift covering ColourSet (pixel deduplication + weighting),
ComputePrincipleComponent (covariance + 4–6 power iters),
ConstructOrdering (sort + dedup), Compress4 (triple-nested partition
search), endpoint quantization, and the final BC1 block packing.

Estimated quality improvement: closes the Phase 5B Arena saturation
gap on green / cyan / magenta. Quantifiable via SSIM(GlEnc, source)
≥ 0.999 on the Pass B / Pass D corpus (current FFmpeg path lands at
~0.999266 / Phase 3B; ClusterFit should clear that and tighten on
worst-case frames).

Defer rgbcx level 10 (with precomputed orderings) as a future
optimization if encode speed becomes a complaint. ClusterFit
single-iteration is the minimum viable upgrade.

---

## Recommendation for Phase 5C.3 — BC4 endpoint search

**Implement rgbcx-style endpoint refinement search.**

Algorithm:
1. Pick initial (min, max) from the 16 block pixels (current behavior).
2. For each candidate (a, b) in (max ± 3) × (min ± 3) ⊂ [0, 255]²:
   - Build the 8-mode palette from (a, b).
   - Fit each of 16 pixels to closest palette entry, sum absolute
     errors.
   - Track lowest-error (a, b).
3. Repeat for 6-mode with (min2, max2) ± 3.
4. Pick lower-error mode.

Complexity: 49 candidates × 16 closest-index fits × 2 modes ≈ 1.6 K
palette evaluations per block. Still trivially fast.

Reasoning:
1. **Directly addresses the chroma-plane saturation issue** observed
   in Phase 5B. The chroma BC4 blocks have most pixels on the
   saturated chroma value plus a few outliers; the ±3 search
   neighborhood is wide enough to recover an endpoint near the
   saturated bulk while letting outliers fall on the interpolated
   palette positions or the reserved 0/255 slots.
2. **Cheap.** Even 49× the work is microseconds per block.
3. **Algorithm is mechanical.** No reference port needed — straight
   from the rgbcx idea, ~100 lines of Swift on top of the existing
   `BC4AlphaBlockEncoder`.
4. **Reusable across DXT5 alpha block + YCG6 luma + YCG6 chroma +
   YG10 luma + YG10 alpha + YG10 chroma.** The single-channel BC4
   primitive is shared everywhere.

Estimated implementation effort: **1–2 hours**. Add an
`encodeBC4Block_hq` variant alongside the existing fast one; wire
into the BC1/BC3 path (DXT5 alpha) and the BC4PlaneEncoder for HQ.

Estimated quality improvement: closes the Phase 5B chroma
desaturation gap on cyan / green. Quantifiable via the existing
`testRoundTripViaGlanceCore` alpha-Δ test (currently mean
|Δ_α| = 0.000 LSB on testsrc2 alpha gradient; on chroma planes the
metric is mean |Δ_RGB| via the YCoCg-inverse round-trip).

Could also consider **Squish-style FixRange** as a complementary
addition: ensure (max - min) ≥ N steps. Cheap to add; minor quality
help. Decide during 5C.3 implementation based on whether the rgbcx
search alone suffices.

---

## Licensing summary

| Encoder | License | Algorithm portability |
|---|---|---|
| FFmpeg `texturedspenc.c` | MIT (Vittorio Giovara 2015) | Already ported as Phase 2A; remains in repo. |
| Squish `clusterfit.cpp` | MIT (Simon Brown 2006 / Ignacio Castano 2007) | Algorithm not copyrightable. Clean Swift implementation with attribution comments is standard practice. |
| bc7enc / rgbcx | MIT or Public Domain (Rich Geldreich) | Same — algorithm reusable, attribution in comments. |

GlEnc's Phase 5C.2 / 5C.3 will be **clean Swift implementations
informed by these references**, not literal ports. The new code
credits the reference algorithm authors in file-header comments,
same convention as Phase 2A's `BC1BlockEncoder.swift` crediting
Giovara / Giesen / Barrett / Collet.

No GPL / LGPL contamination — Phase 5C drops the LGPL-2.1+
`DXVLZWriter.swift` lineage (that's the LZ codec port, separate
question and unchanged by this phase).

---

## Cross-references

- `Sources/GlEncCore/BC1BlockEncoder.swift` — current FFmpeg-port BC1
  encoder.
- `Sources/GlEncCore/BC4AlphaBlockEncoder.swift` — current
  written-from-spec BC4 encoder.
- `DECISIONS-2026-05-09-PassA.md` — Pass A established BC1
  byte-identity-to-ffmpeg as the v0.2.0 dev contract. Phase 5C
  intentionally retires that contract in favor of fidelity-to-source.
- `feedback_fma_byte_identity.md` — FMA contraction rules from
  Phase 2A. Apply to any new float math in 5C.2 / 5C.3 if we want
  the new encoder's output to be deterministic across builds.
- `feedback_human_visual_judgment.md` — the rule that surfaced this
  study: Phase 5B Arena observation > screenshot equivalence read.
- `feedback_glance_standing_rules.md` rule 3 — Resolume is the
  authority for codec correctness. v0.5.0 ship gate is
  "Arena plays GlEnc YG10 + DXT5 + DXT1 + YCG6 with visible color
  fidelity matching source."

---

End of Phase 5C.1 findings. Planner reviews before Phase 5C.2 starts.
