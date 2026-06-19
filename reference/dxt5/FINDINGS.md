# DXT5 byte-archaeology — Pass B findings

**Date:** 2026-05-10
**Source corpus:** 30 frames at 1920×1080@30fps generated via FFmpeg
`testsrc2` filter overlaid with a synthesized alpha mask:
left third α=255, middle third α=128, right third α=⌊x·255/W⌋ ramp.
Saved as PNG sequence and as ProRes 4444 (`yuva444p10le`) `source.mov`.
**Encoders compared:** Resolume Alley, Adobe Media Encoder + Resolume DXV
plugin. (No FFmpeg DXT5 encoder exists; per Pass A decision 4 in
`DECISIONS-2026-05-09.md`, FFmpeg upstream's `dxvenc.c` is DXT1-only.
Pass B is therefore a **two-encoder** comparison.)

> **Reuse note.** Pass A's analysis tooling carried over: atom walker
> (`/tmp/atom_walk.py`) and per-frame walker (`/tmp/per_frame_walk.py`)
> were re-used unchanged. Same `ftyp/wide/mdat/moov`-style layout
> assumption holds.

---

## ⚠ Contradictions with prior decisions (needs planner)

One empirical finding contradicts a locked decision. **Flagged here, not
silently fixed**, per the explicit Pass A→Pass B protocol.

**The "DXT5 frames are really DXT4 with premultiplied alpha" claim does
not hold for this corpus.**

`DECISIONS-2026-05-09.md` decision 4 cites Connor Worley's FFmpeg patch:
> *"DXV files seem to misnomer DXT5 and really encode DXT4 with
> premultiplied alpha. At least, this is what Resolume Alley does."*

Empirical result on `testsrc2` with synthesized α-gradient × Resolume
Alley × AME-with-Resolume-plugin:

In a 200×100 px uniform-color region centered at (820, 540) — source
pixel value `(R,G,B,A) = (255, 255, 0, 128)`:

| Encoder | Decoded mean RGBA | If PREMULT, dec RGB should be |
|---------|-------------------|-------------------------------|
| Alley   | `(255, 255, 0, 128)` | `(128, 128, 0)` |
| AME     | `(255, 239, 0, 128)` | `(128, 128, 0)` |

The decoded R and B channels match source RGB at **full intensity**,
not the ~50% intensity predicted by premultiplication. Alpha is
preserved bit-exactly. The G-channel attenuation in AME's output
(255 → 239, ~−16 LSB) is encoder-side BC1 quantization noise on this
specific block, not premultiplication scaling.

We measured the same straight-RGB behavior on the right α-gradient
region (α≈170: source `(255, 0, 255, 183)` → Alley `(255, 56, 255, 183)`,
G-bias only). FFmpeg's `dxv` decoder also reports `pix_fmt=rgba` (straight)
on the stream, agreeing with the empirical observation.

**Possible explanations** (not investigated, not blocking):
- Connor Worley's claim may have been wrong, may have applied to an
  older Alley build, or may have applied to inputs whose CGImageAlphaInfo
  was already-premultiplied at the encoder boundary (our ProRes 4444
  source has straight alpha in `yuva444p10le`).
- GlanceCore's `CGImageAlphaInfo.premultipliedLast` declaration on
  decoded DXT5 output (cited in DECISIONS-2026-05-09.md) is therefore a
  *metadata claim* about the buffer, not a description of how the bytes
  on disk relate to source RGB. The bytes on disk are the source RGB
  un-premultiplied; the decoder labels them as premultiplied. Whether
  this label is "right" depends on what Resolume Arena's playback
  pipeline does with the decoded buffer — out of scope for Pass B.

**Phase 3 implication:** If the planner accepts the empirical finding,
GlEnc's DXT5 encoder should write straight RGB to the BC1 color block
(no division by α, no multiplication by α/255). This matches both
Alley's and AME's observed behavior. The encoder design then reduces
to: source RGBA → BC1 on RGB straight + BC4 on α independently → 16-byte
DXT5-format block.

The rest of this document records the findings as data; the
strategy decision belongs to the planner.

---

## File-level summary

| File | Size | SHA-256 (truncated) |
|---|---|---|
| `alley.mov` | 5,608,614 B (5,477 KiB) | `512c510008741ef7…` |
| `ame.mov`   | 6,777,738 B (6,619 KiB) | `71183f3c77dbd739…` |

**Bit-identical pairs at file level:** none (expected, as Pass A).

ffprobe summary (both files): `codec_name=dxv`, `codec_tag_string=DXD3`,
`width=1920`, `height=1080`, `r_frame_rate=30/1`, `nb_frames=30`,
`duration=1.000000`, `pix_fmt=rgba`. Identical at the API level;
differences live below the codec abstraction.

**DXT1 vs DXT5 file size comparison** (Alley):
- Alley DXT1 (Pass A): 2,821,668 B
- Alley DXT5 (Pass B): 5,608,614 B
- Ratio: **1.99×** — almost exactly the theoretical 2× from doubling
  per-block size (8 → 16 bytes). LZ savings on the alpha block are
  apparently small for this corpus, where the alpha plane is mostly
  flat.

---

## Atom structure

| File | Layout (top-level) | `moov` placement | `udta` size |
|---|---|---|---|
| `alley.mov` | `ftyp wide mdat moov` | end-of-file | 28 B (just `©swr`) |
| `ame.mov`   | `ftyp moov mdat`      | front (faststart-style) | 5,095 B (`©swr`, `©TIM`, `©TSC`, `©TSZ`, `XMP_`) |

Identical to Pass A's DXT1 finding. Encoder-discretion choice on `moov`
placement and `udta` payload carries over unchanged.

`stbl` substructure is identical in shape to Pass A: skeleton order
`stsd → stts → stsc → stsz → stco` for both encoders. Sizes:

|   | alley | ame |
|---|---|---|
| `stsd` | 102 B | 102 B |
| `stts` | 24 B | 24 B |
| `stsc` | 28 B | 40 B |
| `stsz` | 140 B | 140 B |
| `stco` | 40 B | 48 B |

`stsc`/`stco` differ in run-length structure: Alley emits 6 chunks
(28 B stsc = 1 entry; 40 B stco = 6 offsets), AME emits 8 chunks
(40 B stsc = 2 entries; 48 B stco = 8 offsets). Pass A had 3 chunks
across the board for DXT1. Chunk grouping is encoder-discretion;
playback semantics are unaffected. **GlEnc may use any chunk grouping;
1 chunk total (current Phase 2B behavior) is acceptable.**

---

## `stsd` atom — byte-identical to Pass A's DXT1 stsd

**Headline:** the four 102-byte stsd atoms across `{Alley, AME} × {DXT1, DXT5}`
are **byte-identical**. Same SHA-256:

| File | stsd len | sha256[:16] |
|---|---|---|
| Alley DXT1 (Pass A) | 102 B | `eef02359c036413f` |
| AME   DXT1 (Pass A) | 102 B | `eef02359c036413f` |
| Alley DXT5 (Pass B) | 102 B | `eef02359c036413f` |
| AME   DXT5 (Pass B) | 102 B | `eef02359c036413f` |

Substantive fields:

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
- depth (offset 0x63): `0x18` = **24** — *not* 32, even though DXT5
  carries an alpha channel
- color-table-id (offset 0x64): `0xFFFF` (none)

**Phase 3 invariant:** GlEnc's existing 102-byte stsd from Phase 2B
(see `DXVMOVWriter.swift`) is correct for DXT5 verbatim. **No stsd
changes are required for the DXT5 path.** Depth = 24 is correct for
both DXT1 and DXT5 in DXV3.

(Note on depth: this is the QuickTime stsd `depth` field, which carries
the per-pixel color-component bit-depth. Resolume's choice of 24 for
both DXT1 and DXT5 implies the alpha plane is not counted in `depth`.
Decoder behavior is governed by the per-frame tag, not by depth.)

---

## `tkhd` presentation dimensions

Both encoders write **1920 × 1080** in `tkhd` (presentation dimensions),
not 1920 × 1088 (16-aligned coded). **Confirms** Pass A's Phase 2B
invariant.

---

## Per-frame DXV header (12 bytes)

Both encoders agree on every byte of the per-frame header for all 30
frames:

| Byte offset | Field | Value | Encoder agreement |
|---|---|---|---|
| 0..3 | tag (LE) | `35 54 58 44` = "DXT5" reversed | All 60 frames agree |
| 4 | `version_major+1` | `0x04` (decoder reads as DXV3) | All agree |
| 5 | `version_minor` | `0x00` | All agree |
| 6 | `raw_flag` | `0x00` (compressed, not raw) | All agree |
| 7 | `unknown` | `0x00` | All agree |
| 8..11 | `size` (LE32, payload bytes) | varies per frame | Field role agrees; values differ |

**Findings:**
- The "unknown" byte is **always `0x00`** across all 60 observed frames.
  Locked the same for DXT1 in Pass A; locked here for DXT5 too.
  **GlEnc writes `0x00`. Treat as reserved.**
- `version_major+1=4` and `version_minor=0` — DXV3 v3.0, identical to
  Pass A.
- `raw_flag=0` for all 60 frames in this corpus. The decoder's RAW path
  is not exercised. Recommend a high-entropy or trivial-color follow-up
  corpus to elicit RAW packets and verify each encoder's switch
  threshold.
- Per-frame tag bytes are `35 54 58 44` = "DXT5" written little-endian
  on disk. (Pass A's DXT1 tag was `31 54 58 44`.) **GlEnc's
  `DXVFormat.frameTagBytes` should map the DXT5 frame format to those
  bytes.**

---

## Per-frame payload SHA-256 matrix (the headline result)

Bytes after the 12-byte header, hashed per frame:

| | alley=ame |
|---|---|
| Frames matching | **0 / 30** |

Zero matches. Same result-shape as Pass A's DXT1 finding. Encoders
disagree on every byte of every payload.

**The Phase 3 byte-identity development contract** (analogous to
Phase 2's "byte-identical to FFmpeg") **cannot use either Alley or AME
as a target**, since neither has a public reference implementation
GlEnc can call to regenerate ground-truth from a fresh source.
Phase 3A should ship its own reference encoder design (BC4 alpha
endpoint search + LZ pass extension over Phase 2A's `dxv_compress_dxt1`),
with Phase 3 validation against (a) round-trip via GlanceCore, (b) SSIM
vs source PNG, (c) Resolume Arena playback. Same shape as Phase 2C's
reframed gates, modulo the missing FFmpeg byte-identity reference.

---

## Per-frame payload size

| Encoder | Total payload | Mean per frame | Range |
|---|---|---|---|
| `alley.mov` | 5,607,403 B | 186,913 B | [186,034, 187,808] |
| `ame.mov`   | 6,771,448 B | 225,715 B | [224,561, 226,585] |

AME vs Alley delta: mean **+38,802 B per frame** (AME larger), uniform
across the corpus. AME / Alley payload ratio: **1.208**.

**Interpretation.** Pass A had AME and Alley within ~0.1% of each other
on DXT1 (different bytes, near-identical bitrate). Pass B shows AME
spends substantially more bytes than Alley on DXT5 — the divergence
appears in the alpha-block or alpha-aware LZ region. Possible
explanations:
- AME's LZ pass for DXT5 finds fewer back-references on the alpha
  block stream than Alley's does.
- AME emits a less-tightly-packed alpha block representation (e.g.,
  more 8-bit-mode alpha endpoints vs Alley's 6-bit-mode).
- AME applies a different chunk-segmentation policy for DXT5 that
  affects literal vs back-reference rates.

Without diffing the LZ-decoded block streams we can't tell.
**Out-of-scope for Pass B.** The asymmetry is informational; both
encoders produce Resolume-playable output.

---

## Alpha-channel premultiplied vs straight verification — see contradictions section

Method: decoded frame 0 of both `alley.mov` and `ame.mov` via FFmpeg's
`dxv` decoder (output `pix_fmt=rgba`), saved as PNG, sampled three
200×100 px uniform-color regions in source and decoded outputs.

Source uniform regions (from `frame_0001.png`):

| Region | Center (x,y) | Source mean RGBA | Source α |
|---|---|---|---|
| Left  | (150, 540) | (255, 0, 0, 255) | 255 |
| Mid   | (820, 540) | (255, 255, 0, 128) | 128 |
| Right | (1380, 540) | (255, 0, 255, 183) | ~183 (gradient) |

Decoded mean RGBA in the same regions:

| Region | Alley decoded | AME decoded | If premult, RGB should be |
|---|---|---|---|
| Left  α=255 | (255, 25, 0, 255) | (255, 25, 0, 255) | (255, 0, 0) — straight matches; G has +25 LSB BC1 noise |
| Mid α=128 | **(255, 255, 0, 128)** | **(255, 239, 0, 128)** | **(128, 128, 0) — both encoders fail this prediction** |
| Right α=183 | (255, 56, 255, 183) | (255, 39, 255, 183) | (183, 0, 183) — both encoders fail |

**Conclusion.** Both encoders store **straight RGB** in the BC1 color
block. Alpha is bit-exact through BC4 (max abs error 0 LSB on flat α
regions across both encoders). The Connor-Worley "DXT5 ≡ DXT4
premultiplied" claim does not hold empirically here. See contradictions
section above for the planner.

**G-channel BC1 bias reproduces.** Phase 2C identified an Alley G-bias
of ~+26 LSB across saturated edges. Pass B sees the *same* G-bias on
both Alley and AME for the α=255 region (R/B unchanged, G shifted
~25 LSB). This was previously thought to be Alley-specific; Pass B
shows it's at least dual-encoder. Out-of-scope investigation; not
Phase 3-blocking.

---

## Spec-mandated vs encoder-discretion — Phase 3 actionable summary

### Spec-mandated (encoders agree → GlEnc must match)

- Stream-level codec FourCC: **`DXD3`** (same as DXT1).
- Per-frame 12-byte header layout: identical to DXT1; only `tag` differs.
- Per-frame DXT5 tag: **`35 54 58 44`** ("DXT5" little-endian on disk).
- `version_major+1 = 0x04`, `version_minor = 0x00`, `raw_flag = 0x00`
  (compressed), `unknown = 0x00`.
- `tkhd` carries presentation dimensions (1920 × 1080), not coded
  dimensions.
- `stbl` skeleton: `stsd → stts → stsc → stsz → stco`.
- `stsd` substantive fields: byte-identical to Pass A's DXT1 stsd
  (vendor `FFMP`, depth `0x18`=24, color-table-id `0xFFFF`, dimensions,
  72 DPI). **Same 102 bytes for DXT1 and DXT5.**
- BC1 color block + BC4 alpha block: store **straight RGB** plus
  alpha (per Pass B's contradictions section, modulo planner review).

### Encoder discretion (encoders differ → GlEnc may pick)

- `moov` placement: end-of-file (Alley) or front (AME). **GlEnc:
  end-of-file** (carry-over from Phase 2B).
- `udta` payload: minimal `©swr` only (Alley) or 5 KB XMP (AME).
  **GlEnc: minimal `©swr` = "GlEnc <version>"** (carry-over from
  Phase 2B).
- Chunk grouping (`stsc`/`stco`): 6 chunks (Alley) vs 8 chunks (AME) —
  Phase 2B used 1 chunk total. **GlEnc: 1 chunk** (carry-over).
- BC1 endpoint selection per 4×4 block: encoders differ. **No spec
  mandate.** Phase 2A's BC1 path (FFmpeg-derived, G-bias-free) carries
  over to Phase 3A unchanged.
- BC4 alpha endpoint selection: encoders differ at the byte level.
  **No spec mandate.** Phase 3A picks its own search strategy (FFmpeg's
  `dxvenc.c` doesn't have a BC4 implementation, so this is original
  work — see `DECISIONS-2026-05-09.md` decision 2).
- LZ-pass byte-level encoding for DXT5 (which back-references at
  which positions, alpha-block-vs-color-block prioritization):
  encoders differ. **No spec mandate.**

### What this comparison does not tell us

- Whether Alley's BC4 alpha endpoint search outperforms AME's for
  natural video (vs the synthesized α-gradient corpus, which is mostly
  flat). Out-of-scope.
- Whether Resolume Arena's playback pipeline applies premultiplication
  on its consuming side (and whether GlEnc's straight-RGB output
  composites the same as Alley's straight-RGB output in Arena).
  **Phase 3B validation gate: drop GlEnc DXT5 output into Arena, layer
  with effects + alpha-aware blending, compare to Alley DXT5 of the
  same source.** Same gate Phase 2C used.

---

## Open questions for Pass C (HQ archaeology, before Phase 4)

- Same comparison on YCG6 and YG10 outputs from Alley + AME
  (no FFmpeg HQ encoder exists).
- Do Alley/AME produce identical opcode streams for HQ? (Tests whether
  the opcode stream is spec-mandated or encoder discretion.)
- Pixel-level decode comparison for DXT5 (deferred from Pass B): both
  encoders → decoded RGBA → PSNR vs ProRes source, to ground "encoder
  discretion" findings in actual quality numbers.
- High-entropy / trivial-color corpus to elicit `raw_flag=1` packets
  for DXT5.
- Investigate the dual-encoder G-channel bias (Phase 2C identified
  Alley-specific; Pass B sees both). Possibly a colorspace conversion
  on the encoder side, or an artifact of the FFmpeg `dxv` decoder's
  output. Decode the same files via GlanceCore + a direct BC1 unpacker
  (per Phase 2C method) and compare.

---

## Notes on the analysis pipeline

- Atom walker: `/tmp/atom_walk.py`. Re-used from Pass A, unchanged.
- Per-frame walker (stco + stsc + stsz → per-sample byte ranges):
  `/tmp/per_frame_walk.py`. New for Pass B; reusable for Pass C.
- Source corpus committed via Git LFS: `reference/dxt5/source/source.mov`
  (ProRes 4444), `frame_*.png` (30 PNGs), plus the two encoder outputs
  `alley.mov` and `ame.mov`.
- Decoded comparison frames in `/tmp/dxt5-decode/{alley,ame}_frame0.png`
  (not committed; reproducible from `reference/dxt5/{alley,ame}.mov`
  via `ffmpeg -i $f -frames:v 1 -pix_fmt rgba out.png`).
