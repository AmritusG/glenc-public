# YG10 HQ+alpha byte-archaeology — Pass D findings

**Date:** 2026-05-11
**Source corpus:** 30 frames at 1920×1080 @ 30 fps generated via FFmpeg
`testsrc2` filter overlaid with a synthesized alpha mask (left third
α=255, middle third α=128, right third α gradient `x·255/W`). Saved as
PNG sequence and as ProRes 4444 (`yuva444p12le`) `source.mov`.
**Encoders compared:** Resolume Alley, Adobe Media Encoder + Resolume DXV
plugin. **No FFmpeg HQ encoder exists upstream** (per
`DECISIONS-2026-05-09.md` decision 4); Pass D is therefore a **two-
encoder** comparison, same shape as Pass B and Pass C.

> **FFmpeg dxv.c lines 655-670 (`dxv_decompress_yg10`) is the spec.** YG10
> = two `dxv_decompress_cocg` passes: first emits Y+A interleaved BC4
> blocks into `tex_data`, second emits Co+Cg interleaved BC4 blocks into
> `ctex_data`. Same 17-opcode cgo state machine and same Huffman-
> coded opcode-stream encoding as YCG6.

---

## ⚠ Contradictions with prior decisions

**One Pass B locked rule is partially overturned for YG10.**

`DECISIONS-2026-05-10-PassB.md` (decision: "DXT5 alpha is straight, not
premultiplied") was empirically verified for DXT5 across both Alley and
AME. Pass D measures the same question for YG10 and finds the rule
**splits per encoder**:

- **Alley YG10:** encodes **straight RGB** + straight alpha. Decoded
  pixel (mid region, source `(255,255,0,128)`) → `Y≈183` (close to
  straight prediction Y=191, off by 8 LSB BC4 noise).
- **AME YG10:** encodes **premultiplied RGB** + straight alpha. Decoded
  pixel (mid region, source `(255,255,0,128)`) → `Y≈92` (close to
  premultiplied prediction Y=96, off by 4 LSB BC4 noise).

Empirical evidence at four sample regions on frame 0 (each averaged over
a 100×100 block centered at y=540):

| x | α | Source RGB | Predict straight Y | Predict premult Y | Alley Y | AME Y |
|---|---|---|---|---|---|---|
| 150  | 255 | (255,0,0)     |  64 |  64 |  76.0 |  76.0 |
| 820  | 128 | (255,255,0)   | 191 |  96 | **183.0** |  **92.0** |
| 1500 | 199 | (255,0,255)   | 128 |  99 | **147.0** | **119.0** |
| 1800 | 239 | (40,214,229)  | 174 | 163 | 165.9 | 156.6 |

At α=255 (left, no premult vs straight ambiguity), both encoders agree
at Y=76. At α<255, Alley tracks the straight prediction and AME tracks
the premultiplied prediction.

**Phase 5A implication:** GlEnc must pick one. Recommendation: **encode
straight RGB + straight alpha (match Alley)**. Reasoning:

1. Alley is Resolume's own in-house encoder; Resolume Arena is the
   playback authority by definition. Whatever Alley produces is by
   construction "correct in Arena."
2. DXT5 (v0.3.0) already ships straight RGB + straight alpha per Pass B.
   Matching this for YG10 keeps GlEnc's alpha-bearing variants
   internally consistent.
3. The stsd is byte-identical across Alley and AME for YG10 (see
   below), so the on-disk metadata carries no premult/straight flag —
   the choice is entirely an encoder convention. Arena necessarily
   uses ONE convention for decode; the convention that matches Alley
   is the one Resolume designed Arena around.

AME's premultiplied encoding likely composites differently in Arena (or
matches a different decoder convention used in AME's preview pipeline);
out of Pass D scope to determine which. Phase 5B will validate against
Arena empirically.

**Alpha plane itself is identical across encoders** at the decoded
pixel level (both encoders' α-plane samples at the four test regions
agree to within 0.5 LSB — the source α values 255/128/199/239 round-
trip cleanly). Only the RGB encoding convention differs.

---

## File-level summary

| File | Size | SHA-256 (truncated) |
|---|---|---|
| `alley.mov` | 5,960,781 B (5,821 KiB) | `4734aad0f3feb3be…` |
| `ame.mov`   | 9,216,122 B (9,000 KiB) | `058d9d8c3c99bd4c…` |

Bit-identical pairs at file level: none (expected).

ffprobe summary:

|   | alley | ame |
|---|---|---|
| codec_name | dxv | dxv |
| codec_tag_string | DXD3 | DXD3 |
| width × height | 1920 × 1080 | 1920 × 1080 |
| r_frame_rate | 30/1 | 30/1 |
| nb_frames | 30 | 30 |
| duration | 1.000 s | 1.000 s |
| **pix_fmt** | **yuva420p** | **yuva420p** |
| color_space | ycgco | ycgco |

**AME is 1.546× larger than Alley** (5.96 MB vs 9.22 MB). Different
sign and magnitude from Pass C (YCG6: AME 0.991× Alley) and Pass B
(DXT5: AME 1.208× Alley). Encoder byte-efficiency rank varies per codec
variant and per content.

**Variant-ratio table (Alley):**

| Variant | Alley size | Ratio vs DXT1 |
|---|---|---|
| DXT1 (Pass A)            | 2,821,668 B | 1.000× |
| DXT5 (Pass B)            | 5,608,614 B | 1.99× |
| YCG6 (Pass C, testsrc2)  | 3,582,843 B | 1.27× |
| **YG10 (Pass D, testsrc2+α)** | **5,960,781 B** | **2.11×** |

YG10 lands at ~2.1× DXT1 on testsrc2+alpha. The alpha plane is mostly
flat (left third constant, mid third constant, right third smooth
gradient) so it compresses well; real motion content with varying alpha
would likely be larger.

---

## Atom structure

| File | Layout (top-level) | `moov` placement | `udta` size |
|---|---|---|---|
| `alley.mov` | `ftyp wide mdat moov` | end-of-file | 28 B (just `©swr`) |
| `ame.mov`   | `ftyp moov mdat`      | front (faststart) | 5,095 B (`©swr`, `©TIM`, `©TSC`, `©TSZ`, `XMP_`) |

Identical to Pass A/B/C findings. **Encoder-discretion choice on `moov`
placement and `udta` payload carries unchanged across all four
variants.**

All structural metadata atoms (`mvhd`, `tkhd`, `edts`/`elst`, `mdhd`,
`hdlr×2`, `vmhd`, `dinf`) are byte-equal sized to Pass A/B/C. SHA-256
on body bytes for the metadata atoms common across all four variants:

|   | sha256[:16] (body) | matches Pass C |
|---|---|---|
| tkhd | `484a33003eee9a32` | yes |
| mdhd | `1bb686b3a36d7489` | yes |
| hdlr (video) | `47dfd512c17ef7bd` | yes |
| vmhd | `9cbc73d18d70c94f` | yes |
| hdlr (mdia) | `d735c53dbce295cd` | yes |

`stbl` substructure shape:

|   | alley | ame |
|---|---|---|
| `stsd` | 102 B | 102 B |
| `stts` | 24 B  | 24 B  |
| `stsc` | 28 B  | 28 B  |
| `stsz` | 140 B | 140 B |
| `stco` | 40 B (1 chunk)  | 56 B (4 chunks) |

Skeleton order `stsd → stts → stsc → stsz → stco` — invariant carries.
Chunk-grouping divergence is normal encoder-discretion.

---

## `stsd` atom — byte-identical to Pass A/B/C across all four variants

**Headline structural finding:** the 102-byte `stsd` atom is
**byte-identical** across `{Alley, AME} × {DXT1, DXT5, YCG6, YG10}` —
8 files, 1 SHA-256:

| File | stsd len | sha256[:16] (full atom) |
|---|---|---|
| Alley DXT1 (Pass A) | 102 B | `eef02359c036413f` |
| AME   DXT1 (Pass A) | 102 B | `eef02359c036413f` |
| Alley DXT5 (Pass B) | 102 B | `eef02359c036413f` |
| AME   DXT5 (Pass B) | 102 B | `eef02359c036413f` |
| Alley YCG6 (Pass C) | 102 B | `eef02359c036413f` |
| AME   YCG6 (Pass C) | 102 B | `eef02359c036413f` |
| **Alley YG10 (Pass D)** | **102 B** | **`eef02359c036413f`** |
| **AME   YG10 (Pass D)** | **102 B** | **`eef02359c036413f`** |

Substantive bytes (unchanged from Pass A):

```
0000  00 00 00 66 73 74 73 64 00 00 00 00 00 00 00 01   ...fstsd........
0010  00 00 00 56 44 58 44 33 00 00 00 00 00 00 00 01   ...VDXD3........
0020  00 00 00 00 46 46 4d 50 00 00 02 00 00 00 02 00   ....FFMP........
0030  07 80 04 38 00 48 00 00 00 48 00 00 00 00 00 00   ...8.H...H......
0040  00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00   ................
0050  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00   ................
0060  00 00 00 18 ff ff                                 ......
```

- format (offset 0x14): `DXD3`
- vendor code (offset 0x24): `FFMP`
- width × height (offset 0x30): 1920 × 1080
- DPI h/v (offset 0x34): 72.0 / 72.0
- depth (offset 0x63): `0x18` = **24** — HQ+alpha does NOT promote
  depth to 32. **Variant identity is communicated entirely via the
  per-frame DXV tag**, not via stsd `depth` or any extension atom.
- color-table-id (offset 0x64): `0xFFFF`

**Phase 5A invariant:** GlEnc's existing 102-byte stsd from Phase 2B
(`DXVMOVWriter.swift`) is correct for YG10 verbatim. **Zero
DXVMOVWriter changes are required for the YG10 path.** This now holds
empirically for all four DXV3 variants.

---

## `tkhd` presentation dimensions

Both encoders write **1920 × 1080** in `tkhd` (presentation dimensions),
not 1920 × 1088 (16-aligned coded). Confirms Pass A/B/C invariant for
HQ+alpha. Coded dimensions are derived by the decoder from `tkhd` +
16-pixel alignment.

---

## Per-frame DXV header (12 bytes)

Both encoders agree on every byte of the per-frame header for all 30
frames:

| Byte offset | Field | Value |
|---|---|---|
| 0..3 | tag (LE on disk) | `30 31 47 59` = "YG10" reversed |
| 4 | `version_major+1` | `0x04` |
| 5 | `version_minor` | `0x00` |
| 6 | `raw_flag` | `0x00` (compressed) |
| 7 | `unknown` | `0x00` |
| 8..11 | `size` (LE32, payload bytes) | varies |

**The "unknown" byte is `0x00` across all 60 YG10 frames**, joining
Pass A's 90 DXT1 + Pass B's 60 DXT5 + Pass C's 60 YCG6 = **270
observed frames at `unk = 0x00`**. Treat as reserved. **GlEnc writes
`0x00`.**

Per-frame YG10 tag: `30 31 47 59` LE on disk (vs DXT1 `31 54 58 44`,
DXT5 `35 54 58 44`, YCG6 `36 47 43 59`).

---

## Per-frame payload identity matrix

| | alley = ame |
|---|---|
| Frames matching | **0 / 30** |

Zero pairwise matches across all 30 frames. Same result-shape as Pass
A/B/C. Encoders disagree on every byte of every payload.

**Phase 5A's byte-identity development contract cannot use either
Alley or AME** — both Pass C and Pass D confirm no encoder converges
even on count + structure (op_size diverges except for the A plane —
see below). GlEnc ships its own reference design; validation via
GlanceCore round-trip + Resolume Arena playback + SSIM-vs-source.

---

## Per-frame payload size

| Encoder | Total payload | Mean per frame | Range |
|---|---|---|---|
| `alley.mov` | 5,959,575 B | 198,652 B | [196,723, 200,986] |
| `ame.mov`   | 9,209,851 B | 306,995 B | [305,104, 308,971] |

AME vs Alley delta: mean **+108,342 B per frame** (AME larger),
~uniform across the corpus. AME / Alley payload ratio: **1.545×**.

Encoder byte-efficiency rank across the variants (AME / Alley payload
ratio, this corpus + Pass A/B/C):

| Variant | AME / Alley |
|---|---|
| DXT1 | ~1.002 (within 0.2%) |
| DXT5 | 1.208 |
| YCG6 | 0.990 |
| **YG10** | **1.545** |

AME's HQ+alpha output is the largest disagreement of the four. Some of
this is mechanically explained by the premultiplied-RGB encoding (AME
must emit more BC4 endpoint pairs to represent the color × alpha
combined values — half the dynamic range for the same source).

---

## YG10-specific: four-stream layout

Per `dxv.c:655-670`, YG10 calls `dxv_decompress_cocg` twice. Each call
reads a 12-byte header (op_offset + two op_size's) and produces an
interleaved BC4 stream of two paired channels.

```
payload start (after 12-byte DXV header)
├─ Pass 1 (Y + A → tex_data):
│  ├─ op_offset_YA  LE32      (offset to start of Y opcode stream, +12)
│  ├─ op_size_Y     LE32      (Y opcode count)
│  ├─ op_size_A     LE32      (A opcode count)
│  ├─ BC4 Y+A interleaved     (op_offset_YA - 12 bytes; Y/A 8-byte blocks
│  │                            alternating per cgo state machine)
│  ├─ Y opcode-stream encoding (Huffman: ltable + bitstream)
│  └─ A opcode-stream encoding (Huffman: ltable + bitstream)
└─ Pass 2 (Co + Cg → ctex_data):
   ├─ op_offset_CC  LE32
   ├─ op_size_Co    LE32
   ├─ op_size_Cg    LE32
   ├─ BC4 Co+Cg interleaved   (op_offset_CC - 12 bytes)
   ├─ Co opcode-stream encoding
   └─ Cg opcode-stream encoding
```

Verified on all 60 frames: total parsed payload = stored payload size
exactly (diff = +0) for both Alley and AME → the four-stream parser is
correct.

**Spec-mandated decoded plane sizes (per dxv.c lines 982-1004 for YG10):**
- `tex_size` (Y+A combined) = `(coded_w/4) * (coded_h/4) * 16`
  - For 1920×1088: **2,088,960 B** (double YCG6's tex_size — Y+A pair).
  - Y plane half: `(coded_w/4) * (coded_h/4) * 8` = 1,044,480 B.
  - A plane half: same, 1,044,480 B.
- `ctex_size` (Co+Cg combined) = `(coded_w/8) * (coded_h/8) * 16`
  - For 1920×1088: **522,240 B** (same as YCG6).

**Op-size budgets (per dxv.c lines 1001-1004):**
- op_size[0] = w·h / 16 = 130,560  (Y opcode max)
- op_size[1] = w·h / 32 =  65,280  (Co opcode max)
- op_size[2] = w·h / 32 =  65,280  (Cg opcode max)
- op_size[3] = w·h / 16 = 130,560  (A opcode max — same as Y)

---

## YG10-specific: opcode stream emission counts

Per-frame emitted op_size (mean over 30 frames):

| Stream | Alley mean | AME mean | Alley / MAX | AME / MAX |
|---|---|---|---|---|
| Y  | 15,415  | 49,825  | 0.1181 | 0.3817 |
| A  | 44,281  | 44,281  | 0.3392 | 0.3392 |
| Co | 5,231   | 11,099  | 0.0801 | 0.1700 |
| Cg | 5,253   | 13,294  | 0.0805 | 0.2036 |

**Striking finding: A op_size = 44,281 on EVERY frame across BOTH
encoders.** 60/60 observations identical. Y, Co, Cg op_size all
diverge significantly (Alley 0/30 matches AME on any of those three).

Per-frame convergence summary:

| Stream | Frames where Alley.op_size == AME.op_size |
|---|---|
| Y  | 0 / 30 |
| **A** | **30 / 30** |
| Co | 0 / 30 |
| Cg | 0 / 30 |

**Interpretation:** alpha plane's cgo emission COUNT is fully content-
determined for this corpus. Synthetic alpha (left 1/3 constant α=255,
middle 1/3 constant α=128, right 1/3 monotonic gradient) admits one
optimal opcode plan that both encoders converge to in count — even
though the BYTES emitted differ (BC4 endpoints diverge from block 1
onward; see below).

This is a useful Phase 5A bound: **alpha plane opcode count is a
verifiable target**. GlEnc's encoder, given the same input, should
emit ≈44,281 alpha opcodes on the equivalent corpus.

---

## YG10-specific: opcode-stream encoding modes

For all 60 frames × 4 streams × 2 encoders = **240 mode observations**,
**all 240 = Huffman** (`flag & 3 ≥ 2`).

| Stream | Alley | AME |
|---|---|---|
| Y  | huffman ×30 | huffman ×30 |
| A  | huffman ×30 | huffman ×30 |
| Co | huffman ×30 | huffman ×30 |
| Cg | huffman ×30 | huffman ×30 |

Joins Pass C's 180 observations at 100% Huffman → **420 cumulative
observations at 100% Huffman across HQ paths**. Raw and single-byte
fill modes are not exercised by either reference encoder on this
synthetic corpus.

**Phase 5A implication carries Pass C's recommendation:** v0.5.0 may
ship YG10 using raw opcode mode (`flag & 3 == 0`) for first-correct
output, with Huffman optimization deferred to v0.4.1 / v0.5.1 just as
YCG6 did at v0.4.0. The decoder accepts all three modes; ship gate is
"works in Arena."

---

## YG10-specific: BC4 plane convergence (encoder discretion)

**Verdict: BC4 endpoint search is encoder-discretion for all four
planes (Y, A, Co, Cg)**, with first-block convergence only.

First 16 BC4 alpha blocks (A-half of the Y+A pairs) on frame 1:

| block | Alley A[8..15] | AME A[8..15] | match |
|---|---|---|---|
| 0  | `ffff000000000000` | `ffff000000000000` | yes (constant α=255 literal seed) |
| 1  | `14d8866dfe9f2401` | `866dfe9f2401004d` | no |
| 2  | `000b100000501436` | `4d4cb66ddbb66ddb` | no |
| 3  | `6ddb317f6b488224` | `246c6b2449922449` | no |
| 4..15 | (all diverge) | (all diverge) | no |

→ 1/16 alpha blocks byte-equal on frame 1.

First Y+A pair (frame 1 literal seed): Y converges 1 LSB on endpoints
(Alley `701b...` = 112/27, AME `6f1c...` = 111/28), A converges
exactly (`ffff...` constant α=255). For full 16-byte pair match:

| Frame | full pair match / 32 | Y-half match / 32 | A-half match / 32 |
|---|---|---|---|
| 1  | 0/32 | 0/32 | 1/32 |
| 15 | 1/32 | 1/32 | 1/32 |
| 30 | 1/32 | 1/32 | 1/32 |

Same shape as Pass C BC4 luma — encoder freedom on endpoint selection,
content-determined convergence on constant-color blocks only.

**Phase 5A implication:** alpha BC4 endpoint search has full encoder
freedom. The "alpha bit-exact on flat regions" claim from Pass B
(DXT5) holds for YG10 only on truly constant-α blocks; once content
varies (gradient, anti-aliased edges), the encoders diverge. GlEnc's
existing `BC4AlphaBlockEncoder` from Phase 3A is sufficient for YG10
alpha — same single-channel mechanism.

---

## YG10-specific: Y+A cocg pairing

The cocg state machine for Pass 1 takes two paired channels and
alternates 8-byte block writes per `dxv_decompress_cgo` call (offset=8
means back-refs reach 16 bytes back = same channel's previous block).
For YG10:
- **Pass 1 channels: op_data[0]=Y (luma) + op_data[3]=A (alpha).**
- **Pass 2 channels: op_data[1]=Co + op_data[2]=Cg.**

Note the op_data index swap: YCG6 uses op_data[0] for Y standalone and
op_data[1..2] for Co+Cg; YG10 reuses op_data[0]/[3] for the Y+A pair
and keeps op_data[1..2] for Co+Cg. The decoder allocates four parallel
opcode buffers; the encoder must produce them in the same order.

On-disk byte layout for Y+A interleaved BC4 data:
- bytes [0..7]   = Y[0]   (first luma block — literal seed)
- bytes [8..15]  = A[0]   (first alpha block — literal seed)
- bytes [16..23] = Y[1]   (second luma block — via cgo)
- bytes [24..31] = A[1]   (second alpha block — via cgo)
- ...

Total Y+A BC4 size at 1920×1088 = 2,088,960 B = 130,560 Y blocks ×
8 + 130,560 A blocks × 8 (matching the two op_size[0]/[3] budgets).

This is a strict 1:1 Y/A pairing at the BC4-block level. GlEnc's Phase
5A encoder must emit blocks in this exact interleave.

---

## Spec-mandated invariants — Phase 5A actionable summary

### Carry-over from Pass A/B/C (no changes needed)

- Stream-level codec FourCC: **`DXD3`**.
- Per-frame 12-byte DXV header: `tag(4 LE) + 0x04 + 0x00 + 0x00 (raw) + 0x00 (unknown) + size(4 LE)`.
- Per-frame YG10 tag: **`30 31 47 59`** ("YG10" little-endian on disk).
- `tkhd` carries presentation dimensions, not coded.
- `stbl` skeleton order: `stsd → stts → stsc → stsz → stco`.
- `stsd` 102 B byte-identical to DXT1/DXT5/YCG6 (vendor `FFMP`, depth
  `0x18=24`, color-table-id `0xFFFF`, dims, 72 DPI). **No DXVMOVWriter
  changes for YG10.**
- 16-pixel coded alignment (`coded_h = ((presentation_h + 15) / 16) * 16`).

### New for Pass D (YG10-specific)

- **Two cocg-pass layout** per dxv.c:655-670. First pass = Y+A
  (op_data[0] + op_data[3]); second pass = Co+Cg (op_data[1..2]).
- **Decoded plane sizes:**
  - `tex_size` (Y+A combined) = `(coded_w/4) * (coded_h/4) * 16` = 2,088,960 B at 1920×1088.
  - `ctex_size` (Co+Cg combined) = same as YCG6 = 522,240 B.
- **Op-size maxes:** Y / A = `w·h/16`; Co / Cg = `w·h/32`.
- **Y+A BC4 interleave** at the 8-byte block level: Y[0], A[0], Y[1], A[1], …
- **All four opcode streams** (Y, A, Co, Cg) use Huffman mode (`flag & 3 ≥ 2`) in references.
- **BC4 alpha plane** layout identical to BC4 luma layout (standard BC4: 2 endpoints + 16 × 3-bit indices = 8 bytes). GlEnc's Phase 3A `encodeBC4Block` carries directly.

### Encoder-discretion (encoders differ → GlEnc may pick)

- **Alpha-RGB encoding convention.** Alley uses straight RGB; AME uses
  premultiplied RGB. **GlEnc Phase 5A choice: straight (match Alley).**
  Rationale: Alley is Resolume's in-house encoder, DXT5 v0.3.0 ships
  straight, no on-disk metadata distinguishes the two.
- `moov` placement: end-of-file (carry-over).
- `udta`: minimal `©swr = "GlEnc <version>"` (carry-over).
- Chunk grouping: 1 chunk (carry-over from Phase 2B; both Alley and
  AME diverge from each other on chunk count, encoder-discretion).
- BC4 endpoint search per plane: encoders differ from block 1 (block 0
  converges on constant-color content as expected). **No spec mandate.**
- LZ pass byte-level cgo opcode-stream content: encoders differ. **No spec mandate.**
- Per-stream opcode COUNT: differs except for the A plane on this
  synthetic corpus (60/60 frames identical at 44,281). The A-count
  convergence is striking but may be content-specific — natural alpha
  motion content would likely break it.

---

## Source-alpha normalization implication

`DECISIONS-2026-05-10-PassB.md` locks the rule "DXT5 alpha is straight,
not premultiplied" for GlEnc's DXT5Encoder. Pass D shows YG10 admits
encoder-dependent encoding (Alley straight, AME premult). For
consistency with the DXT5 v0.3.0 ship behavior and matching Resolume
Alley's convention, **GlEnc Phase 5A's YG10Encoder should write
straight RGB to the BC4 luma block and straight alpha to the BC4 alpha
block**. Source `CGImageAlphaInfo` normalization rules (per Pass B
decision) carry over verbatim from DXT5Encoder:

- `.premultipliedFirst / .premultipliedLast` → un-premultiply RGB.
- `.first / .last` → straight RGB and straight alpha as-is.
- `.noneSkipFirst / .noneSkipLast / .none` → α = 255.
- `.alphaOnly` → fail.

YG10Encoder will share this helper with DXT5Encoder (factor or
duplicate).

---

## What this comparison does NOT tell us

- Whether Alley's BC4 alpha endpoint search outperforms AME's for
  **natural alpha content** (real motion graphic with varying alpha).
  The synthetic gradient is extreme; real content may converge or
  diverge differently.
- Whether Resolume Arena composites Alley vs AME YG10 differently.
  Phase 5B's gate: drop GlEnc YG10 output into Arena, layer with
  alpha-aware blending, visually compare to Alley YG10 of the same
  source.
- Per-pixel quality comparison (PSNR / SSIM / max-error) between
  Alley and AME on the same source — deferred to Phase 5B's
  validation harness.

---

## Open questions for Phase 5

### Phase 5A (encoder)

- **Confirm the straight-vs-premult choice in Resolume Arena.** v0.3.0
  DXT5 ships straight and is user-verified in Arena. Phase 5B should
  verify YG10's straight ship by visual diff against Alley YG10 in
  Arena.
- **YG10Encoder structure: extend YCG6Encoder or new top-level?** The
  Y plane in YG10 differs from YCG6's: YG10's Y uses cocg (paired
  with A); YCG6's Y uses yo (standalone). Cleanest design is probably
  a separate `YG10Encoder` that reuses YCoCgTransform + BC4PlaneEncoder
  + DXVHQOpcodeWriter, with a small new orchestrator for the two
  cocg-paired calls.

### Phase 5B (validation)

- Same five-gate methodology as Phase 4B with alpha re-introduced:
  1. Round-trip via GlanceCore.DXVHQDecoder.decompressYG10 (full
     four-plane decode). Pixel-equivalence on RGB ≤ ~5 LSB (HQ gate);
     alpha pixel-Δ ≤ ~4 LSB (BC4 single-channel gate).
  2. Resolume Arena playback (manual). Must composite cleanly with
     alpha blending.
  3. SSIM(GlEnc, source) ≥ 0.995 on RGB.
  4. Alpha pixel-Δ vs source: mean ≤ 2 LSB, max ≤ 8 LSB (Pass B gate,
     carries since BC4 alpha mechanism is identical).
  5. File size: within 2× Alley YG10 (5.96 MB). Pass C lesson: real
     motion content may need v0.5.1 optimizations to hit ≤1.5×.

### Surprising (worth flagging)

- **A op_size convergence at 44,281 across all 60 observations** is
  the headline puzzle. Suggests alpha cgo emission has a
  content-determined optimum that both encoders independently find.
  May or may not generalize to natural alpha content.
- **AME premultiplied YG10 output** is the empirical surprise. The
  Worley FFmpeg patch claim that "DXV files misnomer DXT5 as DXT4
  with premultiplied alpha" was falsified for DXT5 in Pass B but
  apparently *partially* applies to AME's YG10 path. Source-pipeline
  detail or AME-specific behavior; unrelated to GlEnc's ship.
- **YG10 BC4 first-block convergence is weaker than YCG6 Y.** On YCG6,
  the first Y block converged byte-exact between Alley and AME (per
  Pass C). On YG10, the first Y block differs by 1 LSB on endpoints
  (`701b...` vs `6f1c...`). The Y plane is the same source for both
  variants (post YCoCg); the difference is the cocg-vs-yo state
  machine context.

---

## Notes on the analysis pipeline

- Atom walker + per-frame walker: in-line Python (mirrors Pass C).
- Opcode-stream byte-boundary simulator (`sim_fill_ltable`): reused
  from Pass C unchanged. Validates total payload consumption to
  +0 bytes on all 60 frames.
- Alpha straight/premult verification used `ffmpeg -pix_fmt yuva420p
  -f rawvideo` because ffmpeg's `dxv` decoder reports `color_space=
  ycgco` and sws_scale cannot convert ycgco → RGB; raw planar YUV
  output sidesteps the conversion and lets us sample Y/A planes
  directly.
- Source corpus committed via Git LFS: `reference/yg10/source/source.mov`
  (ProRes 4444), `frame_*.png` (30 RGBA PNGs), plus the two encoder
  outputs `alley.mov` and `ame.mov`.
- Decoded comparison frames NOT committed (reproducible via
  `ffmpeg -i alley.mov -frames:v 1 -pix_fmt yuva420p -f rawvideo
  out.yuva`).

---

End of Pass D findings. Planner reviews before commit + tag.
