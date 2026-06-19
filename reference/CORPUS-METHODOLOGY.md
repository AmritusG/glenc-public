# GlEnc test corpus methodology

**Established:** Phase 5C.2.5 (2026-05-11)
**Generators:** `Tests/GlEncTests/CorpusGenerationTests.swift`

## Why this exists

Phase 5C.2 Arena verdict revealed that the prior real-content corpus
chain — Resolume Alley DXV3 export → `ffmpeg` → ProRes 4444 intermediate
→ DXT5 — had multiple lossy stages, masking encoder quality with
upstream pipeline corruption. The corrupted ProRes 4444
`ShroomiesKingdom_5s.mov` was producing JPG-like alpha ringing
artifacts NOT present in the actual PNG ground truth, but our SSIM-vs-
ProRes measurements were treating it as truth. From v0.5.0 onward,
GlEnc measures `SSIM(GlEnc-decoded, source PNG)` where the source PNG
is either:

  (a) synthesized via CoreGraphics — deterministic stress patterns
      with known-correct RGBA bytes; or
  (b) decoded directly via GlanceCore from the original DXV3 source —
      real motion content with the minimum number of lossy stages.

## Synthetic stress corpus — `reference/synthetic-corpus/`

12 PNG test patterns, each 1920×1080 RGBA 8-bit. Each pattern
exercises a specific encoder failure mode and lets us isolate
encoder quality without dependencies on external source video.

| File | Purpose |
|---|---|
| `01-primaries-opaque.png` | Six vertical stripes (red, green, blue, yellow, magenta, cyan), all α=255. Tests YCoCg endpoints at extremes; BC1 endpoint search on 100%-saturated content. |
| `02-primaries-halfalpha.png` | Same six stripes, all α=128. Exercises alpha-mode normalization paths (premult vs straight) across all encoders. |
| `03-near-primaries.png` | 5-LSB inset primaries (250, 5, 5) etc. Tests transform precision at near-saturation; any quantization bias shows up as visible saturation loss. |
| `04-grayscale-ramp.png` | Horizontal black→white gradient. Tests luma fidelity in isolation; chroma should be near-zero throughout — any chroma on this image = transform bug. |
| `05-saturated-gradient-red-green.png` | Horizontal red→green gradient. BC1 endpoint search on smooth high-chroma transitions. |
| `06-saturated-gradient-blue-yellow.png` | Horizontal blue→yellow gradient. Complementary axis to #5. |
| `07-sharp-color-edges.png` | 4-quadrant cyan/magenta/yellow/white. BC1 endpoint selection on 4-color blocks straddling sharp edges. |
| `08-alpha-hard-edge.png` | Left half α=255 (red below), right half α=0 (red below). Tests BC4 alpha endpoint preservation of {0, 255} extremes. |
| `09-alpha-smooth-gradient.png` | α gradient 0→255 horizontally over solid green. Tests BC4 8-level interpolation on smooth alpha. |
| `10-text-on-transparent.png` | Anti-aliased magenta text on transparent. Typical VJ lower-third overlay; tests BC4 alpha edge fidelity on glyph boundaries. |
| `11-gradient-with-chromakey-hole.png` | Diagonal red→blue gradient background with circular α=0 hole in the middle. Mixed-content (smooth gradient + sharp alpha edge) handling. |
| `12-mixed-alpha-saturation.png` | Full-saturation primaries in patches, each patch with a different α (0/64/128/192/255). Tests BC4 alpha × BC1 color interaction; specifically catches premult-vs-straight visual differences across alpha levels. |

Total corpus size: ~2 MB (PNG compression is excellent on the simple
patterns; only the diagonal gradient with chromakey hole exceeds
1 MB because it has many unique pixel values).

## Real-content corpus — `reference/realworld-corpus/`

30 PNG frames, 3840×2160 RGBA 8-bit, decoded directly from
`ShroomiesKingdom_29.mov` via GlanceCore.

**Source:**
`<LOCAL-MEDIA>/ShroomiesKingdom_29.mov` (a local-only DXV3 clip; the original
absolute path was on the author's machine and is intentionally not published)
— 900 frames @ 30 fps, 30 seconds total, DXV3 codec
(per-frame tag `31 54 58 44` = DXT1, no alpha). Resolution 3840×2160.
Visual content: glowing pink/magenta mushrooms with bright highlight
spots, blue flowers, green grass at night.

**Window choice:** frames 199-228 (= 6.63 s .. 7.6 s of the clip).
Selected via `ffprobe -show_entries packet=size -select_streams v -of
csv=p=0` + a sliding-window awk over packet sums: this 30-frame
interval carries the densest summed DXV3 payload (91.2 MB) over any
30-frame window. The clip is content-rich throughout (packet sizes
~2.6 – 3.2 MB across all 900 frames, so any window would have been
acceptable; the densest pick maximizes texture/edge variation).

**Decode path:**

```
ShroomiesKingdom_29.mov
   │
   ▼
DXVDemuxer.demux         (parses MOV atoms, builds frame index)
   │
   ▼
File.seek + read         (per-frame: seek to offset, read `size` bytes)
   │
   ▼
DXVPacketDecoder.parseHeader   (12-byte DXV3 header skip)
DXVPacketDecoder.decompressDXT1  (LZ → BC1 block buffer)
   │
   ▼
CPURender.cgImageFromDXT, variant=.dxt1  (BC1 unpack → CGImage)
   │
   ▼
CGImageDestination + UTType.png  (PNG write at native 4K)
```

Single decode stage. Every byte in the resulting PNGs is what
GlanceCore (the validated decoder used in production by Glance and
CueGlance) considers the canonical RGBA representation of the source
clip.

**Corpus size:** 252 MB (committed via Git LFS). Average ~8.4 MB per
4K RGBA PNG, varies with motion content.

**Source variant note (important).** The corpus is DXT1 (no alpha).
Per-frame tag bytes confirm it. FFprobe reports `pix_fmt=rgba` but
that's FFmpeg's DXV decoder always declaring rgba output — for DXT1
the alpha channel is just 255 throughout. **Real-content alpha
validation needs a separate DXT5 or YG10 source clip.** The synthetic
corpus covers alpha exhaustively in the meantime (#08-#12 specifically
target BC4 alpha + premult/straight interactions).

## Why PNG-direct

- PNG is lossless. RGBA bytes are exactly what the encoder sees.
- No intermediate codecs (ProRes, AVAssetReader colormatrix
  conversion, ffmpeg yuv420 → rgba reconstruction). Eliminates all
  the upstream lossy stages that masked encoder quality in prior
  phases.
- `SSIM(GlEnc-decoded, source PNG)` is a closed-loop measurement of
  encoder quality only — no shared lossy stages between reference and
  test artifact.

## Paired real-content HQ + Normal corpora — `reference/realworld-yg10-corpus/` and `reference/realworld-dxt5-paired-corpus/`

Two PNG corpora decoded from frame-aligned paired DXV3 variants of the
same source content. Added in Phase 5C.3.5 to fill the gap surfaced by
Phase 5C.3 measurement: the prior real-content corpus
(`realworld-corpus/` from ShroomiesKingdom_29) is DXT1-only with α=255
throughout, so BC4 chroma quantization on real alpha-bearing motion
content was never exercised at scale. The Phase 5B Arena
desaturation observation can't be measured against synthetic patterns
alone — they have flat-color stripes that hit BC4's constant-block
fast path. Real motion-graphic content with smooth chroma transitions
and hard alpha edges is where BC4 endpoint search choices actually
matter.

### Sources

- `realworld-yg10-corpus/`: decoded from
  `<LOCAL-MEDIA>/ShroomiesKingdom_05_DXV High Quality With Alpha.mov`
  (a local-only clip; 3840×2160, 30 fps, 300 frames / 10 s, **YG10** variant).
- `realworld-dxt5-paired-corpus/`: decoded from the matching
  `<LOCAL-MEDIA>/ShroomiesKingdom_05_DXV Normal Quality With Alpha.mov`
  (a local-only clip; 3840×2160, 30 fps, 300 frames / 10 s, **DXT5** variant).
- Both files render the same source content from Resolume Alley as
  two DXV3 variants. Frame indices are aligned by construction —
  `frame_0001.png` in each corpus represents the same source moment
  encoded through different DXV3 paths. Visual side-by-side shows the
  real-content quality tradeoff between Normal and HQ.

### Window choice

Densest 30-frame interval per packet-size sliding window over the
YG10 file: **frames 65..94** (= 2.17 s..3.13 s, 48.4 MB summed YG10
payload — packet sizes range 1.26..1.73 MB across the 300-frame
clip). Same window applies to both files by frame alignment.

### Decode paths

YG10 (HQ + alpha):
```
ShroomiesKingdom_05_DXV High Quality With Alpha.mov
   │
   ▼
DXVDemuxer.demux                             (variant detected as YG10)
   │
   ▼
File.seek + read                             (per-frame packet bytes)
   │
   ▼
DXVPacketDecoder.parseHeader
DXVHQDecoder.decompressYG10(payload, codedWidth, codedHeight)
   │
   ▼  YG10Result with y, a, co, cg planes
   │
CPURender.cgImageFromHQ(y, co, cg, a,
                        width, height,
                        chromaWidth = w/2, chromaHeight = h/2)
   │
   ▼
PNG write via ImageIO + UTType.png            (4K RGBA PNG)
```

DXT5 (Normal + alpha):
```
ShroomiesKingdom_05_DXV Normal Quality With Alpha.mov
   │
   ▼
DXVDemuxer.demux                             (variant detected as DXT5)
   │
   ▼
File.seek + read
   │
   ▼
DXVPacketDecoder.parseHeader
DXVPacketDecoder.decompressDXT5(payload, expectedSize: blocks * 16)
   │
   ▼  BC3 byte buffer
CPURender.cgImageFromDXT(dxtBytes, variant=.dxt5, width, height)
   │
   ▼
PNG write via ImageIO
```

### Corpus sizes

- `realworld-yg10-corpus/source/`: 30 PNGs @ 3840×2160 RGBA, **116.6 MB**
  total (avg 3.9 MB/frame).
- `realworld-dxt5-paired-corpus/source/`: 30 PNGs @ 3840×2160 RGBA,
  **112.8 MB** total (avg 3.8 MB/frame).
- Both LFS-tracked via `reference/**/*.png filter=lfs`.

### Pinned-API note

GlanceCore@0.4.13 (the version pinned in `Package.resolved`) has the
`CPURender.cgImageFromHQ` signature WITHOUT a `displayWidth`
parameter. The local Glance source has added that parameter post-
0.4.13 but it isn't exposed through the pinned binary. Our 4K source
is already 16-aligned (3840 and 2160 are both /16), so the pinned API
suffices — no crop step needed.

### Purpose

Real-content gold-standard for measuring BC4 endpoint-search quality
on motion-graphic alpha content. Phase 5C.4 onward uses these
corpora as the SSIM-vs-source reference for HQ encoder work.

## What this replaces from prior validation

- `reference/dxt1/source/`, `reference/dxt5/source/`,
  `reference/ycg6/source/`, `reference/yg10/source/` — these stay
  for archival reference. They are the testsrc2-based corpora from
  Phase 2/3/4/5 archaeology passes. Still useful for unit-level
  encoder testing.
- `reference/dxt5/realworld-source/` +
  `reference/dxt5/realworld-alley.mov` +
  `reference/dxt5/realworld-glenc.mov` — **superseded** by
  `realworld-corpus/`. The prior ShroomiesKingdom_5s ProRes
  intermediate had upstream corruption (per Phase 5C.2 Arena verdict)
  and shouldn't be trusted as a ground-truth reference. These files
  remain in the repo as historical reference; future SSIM measurement
  uses `realworld-corpus/` instead.
- `Tests/GlEncTests/Phase3BResultsTests.swift` and `Phase3BSizeTest`
  still read the prior `realworld-glenc.mov` paths. Those tests
  should migrate to the new corpus in Phase 5C.2.7 onward once
  measurement reframing happens; until then they continue to
  reference the historical (corrupted) corpus but no longer serve as
  the v0.5.0 ship gate.

## How to regenerate

Both corpora are generated by env-gated tests in
`Tests/GlEncTests/CorpusGenerationTests.swift`:

```bash
GLENC_GEN_SYNTHETIC=1 swift test -c release \
    --filter "CorpusGenerationTests/testGenerateSyntheticCorpus"

GLENC_GEN_REALWORLD=1 swift test -c release \
    --filter "CorpusGenerationTests/testGenerateRealworldCorpus"
```

The real-world generator requires the source clip at the path noted
above. The synthetic generator is fully self-contained.

## Open follow-ups

- **Alpha-bearing real-content corpus**: ShroomiesKingdom_29 is
  DXT1, so the real-content corpus doesn't exercise the BC4 alpha
  path. Future option: pick a separate alpha-bearing VJ clip (DXT5
  or YG10) and decode 30 frames the same way into
  `reference/realworld-alpha-corpus/`.
- **Resolution flexibility**: currently the real-content corpus is
  native 4K. A 1080p variant (decoded at 4K then `CGImage`-scaled to
  1080p — note that adds one resampling stage) would be ~63 MB
  instead of 252 MB. Defer until size becomes a practical problem.
