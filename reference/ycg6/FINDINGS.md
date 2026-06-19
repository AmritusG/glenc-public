# YCG6 HQ byte-archaeology — Pass C findings

**Date:** 2026-05-11
**Source corpus:** 30 frames at 1920×1080 @ 30 fps generated via FFmpeg
`testsrc2` filter (no alpha — YCG6 is the HQ no-alpha variant). Saved as
PNG sequence and as ProRes 4444 (`yuva444p10le` requested, ffmpeg
auto-promoted to `yuva444p12le` since ProRes 4444 stores 12 bit
internally; alpha channel synthesized at 255 throughout since source
PNGs are RGB-only).
**Encoders compared:** Resolume Alley, Adobe Media Encoder + Resolume
DXV plugin. **No FFmpeg HQ encoder exists upstream** (per
`DECISIONS-2026-05-09.md` decision 4 — `dxvenc.c` is DXT1-only); Pass C
is therefore a **two-encoder** comparison, same shape as Pass B.

> **FFmpeg dxv decoder is the spec reference for HQ paths.** dxv.c lines
> 639-670 (`dxv_decompress_ycg6` + `dxv_decompress_yg10`), 597-636
> (`dxv_decompress_yo`), 541-595 (`dxv_decompress_cocg`), 301-540
> (`dxv_decompress_cgo`), 274-298 (`dxv_decompress_opcodes`), 147-188
> (`fill_ltable`), 191-272 (`fill_optable` + `get_opcodes`). GlanceCore's
> `DXVHQDecoder` / `DXVHQOpcodeDecoder` / `DXVHQCgoDecoder` are equally
> authoritative (faithful Swift ports of these paths).

> **Reuse note.** Pass A's analysis tooling carried over conceptually
> (atom walker, per-frame walker). The opcode-stream simulator
> (`sim_fill_ltable` + `sim_get_opcodes` to compute byte boundaries
> without full Huffman decode) is new for Pass C; reusable for Pass D
> when YG10 lands.

---

## ⚠ Contradictions with prior decisions / handover

**One quantitative expectation falsified, no locked decisions overturned.**

The user-supplied Pass C kickoff stated: *"HQ files are dramatically
larger than DXT1/DXT5 — expect ~5-10× DXT1 sizes for the same source;
HQ should land 12-25 MB range."*

Empirical result on `testsrc2`:

| Variant | Alley | AME | Ratio vs DXT1 Alley |
|---|---|---|---|
| DXT1 (Pass A) | 2,821,668 B | 2,826,362 B | 1.000× |
| DXT5 (Pass B) | 5,608,614 B | 6,777,738 B | 1.99× |
| **YCG6 (Pass C)** | **3,582,843 B** | **3,551,267 B** | **1.27×** |

YCG6 lands at **~1.27× DXT1**, not 5-10×. Pass C did NOT use real motion
content — testsrc2's long flat-color regions and color-bar gradients
compress exceptionally well in HQ because BC4 endpoint search converges
to single-endpoint pairs on flat regions and the cgo cascade encodes
"copy previous block" cheaply via 2-bit opcodes. Real motion-graphic
content (e.g. ShroomiesKingdom from Pass B's secondary corpus) would
likely show a much higher ratio. **Open question for Phase 4B**: re-run
size sanity on a content-rich corpus before locking a Phase 4 file-size
gate.

**No locked decisions** in `DECISIONS-2026-05-09.md`, `…-PassA.md`, or
`…-PassB.md` overturned. All Pass A/B spec-mandated invariants carry
over to YCG6 unchanged (stsd, tkhd, per-frame DXV header, stbl skeleton,
etc. — see §"Spec-mandated invariants" below).

---

## Source (testsrc2 1920×1080, no alpha)

- 30 PNG frames at `reference/ycg6/source/frame_NNNN.png`
  (1920×1080, 8-bit RGB, non-interlaced)
- ProRes 4444 intermediate at `reference/ycg6/source/source.mov`
  (`prores (4444)`, `yuva444p12le`, 1920×1080, 30 fps, 30 frames, 1.000 s)

The corpus deliberately omits alpha. YCG6 carries no alpha plane;
YG10 (Phase 5) will add the alpha-aware corpus separately.

---

## File-level summary

| File | Size | SHA-256 (truncated) |
|---|---|---|
| `alley.mov` | 3,582,843 B (3,498 KiB) | `07810d219249a1aa…` |
| `ame.mov`   | 3,551,267 B (3,468 KiB) | `6f78f01f70c93b94…` |

Bit-identical pairs at file level: none (expected).

ffprobe summary (both files): `codec_name=dxv`,
`codec_tag_string=DXD3`, `width=1920`, `height=1080`,
`r_frame_rate=30/1`, `nb_frames=30`, `duration=1.000000`,
**`pix_fmt=yuv420p`** (vs DXT1/DXT5's `pix_fmt=rgba`). The FFmpeg dxv
decoder explicitly reports YUV-4:2:0 for YCG6, confirming half-resolution
chroma at the API level before any byte-level investigation.

**AME is smaller than Alley on YCG6** (-0.88% per file, -1235 B mean per
frame). This is the **opposite** of Pass B's DXT5 finding (AME +20.8%
vs Alley). Encoder byte-efficiency rank therefore varies by codec
variant — not a structural property of either tool.

---

## Atom structure

| File | Layout (top-level) | `moov` placement | `udta` size |
|---|---|---|---|
| `alley.mov` | `ftyp wide mdat moov` | end-of-file | 28 B (just `©swr`) |
| `ame.mov`   | `ftyp moov mdat`      | front (faststart-style) | 5,095 B (`©swr`, `©TIM`, `©TSC`, `©TSZ`, `XMP_`) |

Identical to Pass A's DXT1 and Pass B's DXT5 findings. **Encoder-discretion
choice on `moov` placement and `udta` payload carries unchanged across
all three variants.**

All structural metadata atoms (`mvhd`, `tkhd`, `edts`/`elst`, `mdhd`,
`hdlr×2`, `vmhd`, `dinf`) are **byte-equal sized** to Pass A/B (108 /
92 / 36+28 / 32 / 45+44 / 20 / 36). They're spec-mandated regardless of
variant — GlEnc's Phase 2B writer needs no changes for Phase 4A here.

`stbl` substructure shape identical to Pass A/B:

|   | alley | ame |
|---|---|---|
| `stsd` | 102 B | 102 B |
| `stts` | 24 B | 24 B |
| `stsc` | 40 B | 40 B |
| `stsz` | 140 B | 140 B |
| `stco` | 32 B | 32 B |

Skeleton order `stsd → stts → stsc → stsz → stco` — invariant carries.

**Chunk grouping (notable):** both Alley AND AME chose **4 chunks**,
`stsc = [(1,8,1), (4,6,1)]` = 8+8+8+6 frames. Different from Pass A
(3 chunks DXT1) and Pass B (6 Alley / 8 AME for DXT5). Whether the
identical chunk count between Alley and AME on YCG6 is coincidence or
convention isn't determinable from a single corpus. **GlEnc may use any
chunk grouping; 1 chunk total (current behavior) remains acceptable.**

---

## `stsd` atom — byte-identical to Pass A's DXT1 and Pass B's DXT5

**Headline structural finding:** the 102-byte `stsd` atom is
**byte-identical** across `{Alley, AME} × {DXT1, DXT5, YCG6}`. Same
SHA-256:

| File | stsd len | sha256[:16] |
|---|---|---|
| Alley DXT1 (Pass A) | 102 B | `eef02359c036413f` |
| AME   DXT1 (Pass A) | 102 B | `eef02359c036413f` |
| Alley DXT5 (Pass B) | 102 B | `eef02359c036413f` |
| AME   DXT5 (Pass B) | 102 B | `eef02359c036413f` |
| **Alley YCG6 (Pass C)** | **102 B** | **`eef02359c036413f`** |
| **AME   YCG6 (Pass C)** | **102 B** | **`eef02359c036413f`** |

Substantive bytes:

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
- depth (offset 0x63): **`0x18` = 24** — **HQ does NOT promote depth to 32**.
  HQ carries higher per-pixel chroma fidelity than DXT1/DXT5 but the
  depth field stays the same. **Variant identity is communicated via the
  per-frame tag, NOT via stsd `depth`.**
- color-table-id (offset 0x64): `0xFFFF` (none)

**Phase 4A invariant:** GlEnc's existing 102-byte stsd from Phase 2B
(`DXVMOVWriter.swift`) is correct for YCG6 verbatim. **No stsd changes
required for the YCG6 path.** And by inductive extrapolation, no stsd
changes required for YG10 either (Phase 5) — though we'll verify
empirically when YG10 archaeology runs.

---

## `tkhd` presentation dimensions

Both encoders write **1920 × 1080** in `tkhd` (presentation
dimensions), not 1920 × 1088 (16-aligned coded). **Confirms** Pass A/B
invariant for HQ. Coded dimensions (1920 × 1088) are not stored in any
atom — they're computed by the decoder from `tkhd` presentation +
16-pixel alignment.

---

## Per-frame DXV header (12 bytes) — all Pass A/B invariants carry

Both encoders agree on every byte of the per-frame header for all 30
frames:

| Byte offset | Field | Value | Encoder agreement |
|---|---|---|---|
| 0..3 | tag (LE on disk) | `36 47 43 59` = "YCG6" reversed | All 60 frames agree |
| 4 | `version_major+1` | `0x04` (decoder reads as DXV3) | All agree |
| 5 | `version_minor` | `0x00` | All agree |
| 6 | `raw_flag` | `0x00` (compressed, not raw) | All agree |
| 7 | `unknown` | `0x00` | All agree |
| 8..11 | `size` (LE32, payload bytes) | varies per frame | Field role agrees; values differ |

- **The "unknown" byte is `0x00` across all 60 YCG6 frames**, joining
  Pass A's 90 DXT1 frames and Pass B's 60 DXT5 frames at `0x00`. Total
  observed evidence: **210 frames × 0x00 unknown** across DXT1+DXT5+YCG6.
  Treat as reserved/padding. **GlEnc writes `0x00`.** Invariant locked.
- `version_major+1=4`, `version_minor=0` — DXV3 v3.0, identical to Pass A/B.
- `raw_flag=0` for all 60 frames in this corpus. The RAW path is not
  exercised (consistent with Pass A/B). Same recommendation: a
  high-entropy / trivial-color follow-up corpus would elicit
  `raw_flag=1` packets if/when we need to characterize that path.
- Per-frame tag for YCG6: `36 47 43 59` LE on disk = "YCG6" (vs Pass A's
  DXT1 `31 54 58 44` and Pass B's DXT5 `35 54 58 44`).

---

## Per-frame payload SHA-256 matrix

Bytes after the 12-byte header, hashed per frame:

| | alley=ame |
|---|---|
| Frames matching | **0 / 30** |

Zero matches. Same result-shape as Pass A (DXT1) and Pass B (DXT5).
Encoders disagree on **every byte of every payload**.

GlEnc Phase 4A's byte-identity development contract (analogous to
Phase 2A's "byte-identical to FFmpeg") **cannot use either Alley or
AME as a target** — no public reference HQ encoder exists. Phase 4A
ships its own reference design, with validation against
(a) round-trip via GlanceCore's `DXVHQDecoder`, (b) SSIM-vs-source on
RGB after decode, (c) Resolume Arena playback. Same shape as Phase 3A's
gates, modulo the missing FFmpeg byte-identity reference.

---

## Per-frame payload size

| Encoder | Total payload | Mean per frame | Range |
|---|---|---|---|
| `alley.mov` | 3,581,988 B | 119,400 B | [117,339, 121,627] |
| `ame.mov`   | 3,545,353 B | 118,178 B | [116,283, 120,348] |

AME vs Alley delta: mean **-1,222 B per frame** (AME smaller), uniform
across the corpus. AME / Alley payload ratio: **0.990** (AME 1.0 %
smaller per frame). Pass B's DXT5 had AME +20.8 % vs Alley; YCG6 has AME
-1.0 %. The byte-efficiency rank flips per codec variant.

---

## HQ-specific: per-frame payload layout

Derived from `dxv.c:597-670`. For YCG6 each frame's payload (after the
12-byte DXV header) is structured as **Y plane** followed by **Co+Cg
combined plane**:

```
payload start
├─ Y plane (dxv_decompress_yo):
│  ├─ op_offset_Y  LE32      (offset from this point to start of Y opcode stream, +8)
│  ├─ op_size_Y    LE32      (emitted Y opcode count)
│  ├─ BC4 luma data          (op_offset_Y - 8 bytes; LZ-compressed via cgo)
│  └─ Y opcode-stream encoding (skip_Y bytes; raw/fill/Huffman per first byte)
├─ Cocg plane (dxv_decompress_cocg):
│  ├─ op_offset_C  LE32      (offset from this point to start of Co opcode stream, +12)
│  ├─ op_size_Co   LE32      (emitted Co opcode count)
│  ├─ op_size_Cg   LE32      (emitted Cg opcode count)
│  ├─ BC4 chroma data        (op_offset_C - 12 bytes; Co+Cg interleaved per cgo)
│  ├─ Co opcode-stream encoding (skip_Co bytes)
│  └─ Cg opcode-stream encoding (skip_Cg bytes)
```

Layout reconstruction verified on frame 1 for both encoders: total
consumed = payload size exactly (diff +0). The Huffman skip count
required a Python port of `fill_ltable` + the `get_opcodes`
`size_in_bits` head; both work without doing the full Huffman decode.

---

## HQ-specific: opcode-stream sizes (Y / Co / Cg)

Theoretical maxima at coded 1920×1088:

| Stream | MAX_OP (= coded_w * coded_h / divisor) | divisor |
|---|---|---|
| Y  | 130,560 | 16 |
| Co | 65,280  | 32 |
| Cg | 65,280  | 32 |

Per-frame emitted op_size (mean over 30 frames):

| Encoder | Y mean | Co mean | Cg mean | Y/MAX | Co/MAX | Cg/MAX |
|---|---|---|---|---|---|---|
| Alley | 15,642 | 5,255 | 5,276 | 0.1198 | 0.0805 | 0.0808 |
| AME   | 15,573 | 5,257 | 5,284 | 0.1193 | 0.0805 | 0.0809 |

**Both encoders converge to within ~0.5% on opcode count** despite
emitting different on-disk bytes. **Implication for Phase 4A:** cgo
opcode emission is largely determined by source content + BC4
endpoint choices, with little encoder freedom in *count*. The freedom
is in *what each opcode is* (which back-reference at which position)
and *how the BC4 endpoints get picked*.

Op counts at ~8-12% of MAX confirm cgo's heavy use of implicit
"continue 2-block run" coding — most blocks are encoded without an
explicit opcode.

---

## HQ-specific: opcode-stream encoding modes

For all 90 streams (Y/Co/Cg × 30 frames) in each of the 2 encoders =
**180 mode observations**, **all 180 = Huffman**.

| Stream | Alley | AME |
|---|---|---|
| Y  | huffman ×30 | huffman ×30 |
| Co | huffman ×30 | huffman ×30 |
| Cg | huffman ×30 | huffman ×30 |

Per `dxv_decompress_opcodes` (dxv.c:274-298), `flag & 3` selects:
`0 → raw`, `1 → single-byte fill`, `>=2 → Huffman`. Both Alley and AME
emit Huffman exclusively for testsrc2-like content. **Implication for
Phase 4A:** implementing only Huffman mode is sufficient for v0.4.0 on
content-rich frames. Raw and single-fill modes may be needed for
degenerate inputs (constant-color frames, raw_flag=1 RAW packets) —
**deferred until empirically observed**, same approach as Phase 3A's
DXT5 raw_flag deferral.

The Huffman encoding (`fill_ltable` + `fill_optable` + `get_opcodes` in
dxv.c:147-272) is order-1 frequency-coded over the alphabet of byte
values 0..255 emitted by cgo. Writing the encoder is **original work**
for Phase 4A — no FFmpeg reference exists. Reference for the *decoder*
is dxv.c and GlanceCore's port.

---

## HQ-specific: BC4 luma endpoint determinism (encoder discretion)

**Verdict: BC4 luma endpoint search is encoder-discretion**, not
spec-mandated. First-block convergence only.

Comparing first 64 on-disk BC4 luma blocks (8 bytes each = 512 B
window) between Alley and AME for frames 1-5:

| Frame | Identical blocks / 64 | First divergent block |
|---|---|---|
| 1 | 3 / 64 | 3 |
| 2 | 1 / 64 | 1 |
| 3 | 1 / 64 | 1 |
| 4 | 1 / 64 | 1 |
| 5 | 1 / 64 | 1 |

Frame 1's first 24 bytes (3 BC4 blocks) are byte-identical between Alley
and AME; block 3 onward diverge. From frame 2 only block 0 converges.
Same shape as Pass A's BC1 finding (block 0 always literal → both
encoders converge there; downstream blocks diverge once LZ back-refs
kick in).

**Implication for Phase 4A:** GlEnc's BC4 luma endpoint search has full
encoder freedom. There's no byte-identity target. Optimization criterion
is "minimize block-level MSE on input pixels" — squish-style exhaustive
search over candidate (min, max) endpoint pairs converges in milliseconds
per block. Reuse Phase 3A's BC4 alpha endpoint search code as a starting
point (single-channel block compression is identical mechanism, just
different input source — alpha for DXT5 vs luma for YCG6).

---

## HQ-specific: BC4 chroma endpoint determinism

**Verdict: BC4 chroma is also encoder-discretion**, but converges more
often than luma.

Comparing first 64 on-disk BC4 chroma blocks (Co+Cg interleaved per cgo
state machine):

| Frame | Identical blocks / 64 | First divergent block |
|---|---|---|
| 1 |  7 / 64 | 1 |
| 2 |  7 / 64 | 0 |
| 3 | 26 / 64 | 0 |
| 4 | 20 / 64 | 0 |
| 5 |  8 / 64 | 0 |

Chroma converges 10-40% of the time vs luma's 1-5%. Plausible reason:
after YCoCg transform on flat color regions, chroma values cluster in a
narrower range than luma, giving the BC4 endpoint search fewer candidate
(min, max) pairs and converging more often across encoders. Not
spec-mandated; Phase 4A's chroma encoder has the same freedom as luma.

---

## HQ-specific: chroma subsampling ratio verification

Per `dxv.c:982-1004`, at coded 1920×1088:

- `tex_size_Y` (decoded luma BC4 buffer) =
  `coded_w / (raw_ratio_Y / 1) * coded_h / TEXTURE_BLOCK_H * tex_ratio_Y`
  = `1920/4 * 1088/4 * 8` = **1,044,480 B**
- `ctex_size` (decoded Co+Cg combined buffer, both planes interleaved) =
  `coded_w/2 / ctex_raw_ratio * coded_h/2 / TEXTURE_BLOCK_H * ctex_tex_ratio`
  = `1920/2/4 * 1088/2/4 * 16` = **522,240 B**
- **Decoded ratio luma : (Co+Cg combined) = 2:1 exactly** — confirms the
  HANDOVER §3 prediction "Co and Cg planes typically at half resolution"
  with the proviso that "half" means "half per dimension, so 1/4 area
  per plane × 2 planes = 1/2 luma area."

On-disk (LZ-compressed) byte ratio is a different question (informational,
not spec):

| Encoder | Σ BC4_Y bytes (30 frames) | Σ BC4_C bytes (30 frames) | On-disk Y : C ratio |
|---|---|---|---|
| Alley | 2,017,294 | 1,272,071 | 1.586 |
| AME   | 1,986,987 | 1,264,077 | 1.572 |

On-disk ratio is ~1.58 because chroma plane has fewer LZ back-ref
opportunities (less spatial redundancy after YCoCg + half-res). This is
encoder-discretion territory and varies per encoder per content type.
**The 2:1 ratio is on the decoded buffers, and that's what GlEnc must
produce.** Phase 4A allocates `tex_data` and `ctex_data` with the exact
sizes the decoder expects; the on-disk byte ratio falls out of the LZ
compression efficiency naturally.

ffprobe reporting `pix_fmt=yuv420p` for both files corroborates: 4:2:0
chroma subsampling, half-res per dimension. This is the FFmpeg dxv
decoder's API-level interpretation of the HQ geometry.

---

## Spec-mandated invariants — Phase 4A actionable summary

### Carry-over from Pass A and Pass B (no changes needed)

- Stream-level codec FourCC: **`DXD3`**.
- Per-frame 12-byte header layout: `tag(4 LE) + version_major+1=0x04 + version_minor=0x00 + raw_flag=0x00 + unknown=0x00 + size(4 LE)`.
- Per-frame DXV header tag for YCG6: **`36 47 43 59`** ("YCG6" little-endian on disk). `DXVFormat.frameTagBytes` already includes this mapping per Pass C verification.
- `tkhd` carries presentation dimensions (1920 × 1080), not coded dimensions (1920 × 1088).
- `stbl` skeleton order: `stsd → stts → stsc → stsz → stco`.
- `stsd` substantive fields: byte-identical to Pass A's DXT1 stsd
  (vendor `FFMP`, depth `0x18 = 24`, color-table-id `0xFFFF`,
  dimensions, 72 DPI). **Same 102 bytes for DXT1 and DXT5 and YCG6.**

### New for Pass C (YCG6-specific, carries to YG10 with one addition)

- **16-pixel coded alignment.** `coded_h` is `((presentation_h + 15) // 16) * 16` — for 1080p input, `coded_h = 1088`. `coded_w` for 1920 is already 16-aligned (no change). Pad the BC4 luma/chroma input planes with zeros for the extra rows.
- **Y plane on-disk layout** (dxv_decompress_yo): `[op_offset_Y LE32][op_size_Y LE32][BC4 luma data: op_offset_Y - 8 bytes][Y opcode stream: skip_Y bytes]`.
  - `op_offset_Y` is the byte distance from "current position after the 8-byte header" to the start of the opcode-stream encoding. So `BC4 luma data length = op_offset_Y - 8` bytes; total Y plane on disk = `op_offset_Y + skip_Y` bytes.
  - `op_size_Y` is the *emitted* opcode count (not max). For 1920×1088 content, MAX_OP_Y = 130,560; observed emitted counts on testsrc2 are ~12% of MAX.
- **Cocg plane on-disk layout** (dxv_decompress_cocg): `[op_offset_C LE32][op_size_Co LE32][op_size_Cg LE32][BC4 chroma data: op_offset_C - 12 bytes][Co opcode stream: skip_Co bytes][Cg opcode stream: skip_Cg bytes]`.
- **Co/Cg interleaving inside BC4 chroma data**: alternating 4×4 chroma blocks via two `dxv_decompress_cgo` calls (dxv.c:582-588), each with its own opcode stream and state.
- **Decoded plane sizes (exact, must match):**
  - tex_size_Y  = `(coded_w / 4) * (coded_h / 4) * 8`   (e.g. 1920×1088 → 1,044,480 B)
  - ctex_size   = `(coded_w/2 / 4) * (coded_h/2 / 4) * 16` (e.g. 522,240 B for both planes combined)
- **Opcode stream modes** per `dxv_decompress_opcodes` (dxv.c:274-298): one of `{raw, single-byte fill, Huffman}` selected by `flag & 3` of the first byte. Both Alley and AME use Huffman exclusively on testsrc2 content (180/180 = 100%). Phase 4A v0.4.0 implements **Huffman mode only**; defer raw/fill modes until empirically observed.
- **BC4 block format** (8 bytes per block): standard BC4 — `[endpoint0 (1 B)][endpoint1 (1 B)][16 × 3-bit indices packed into 6 B]`. Identical bit-layout to Pass B's DXT5 alpha block.
- **cgo opcode state machine** (dxv.c:301-540): 17 opcodes total. GlanceCore's `DXVHQCgoDecoder.swift` is the spec reference for what each opcode means. Phase 4A's encoder must MAKE the opcode choices — research-grade work; emit minimum complexity (op-1 / op-2 / op-3 / op-7-ish baseline) first, then iterate. v0.4.0 goal: Resolume-playable output. v0.4.1+ goal: file-size reduction toward Alley's bitrate.

### YG10 differences (Phase 5, locked here pre-emptively from dxv.c:655-670)

- Per-frame tag: `30 31 47 59` ("YG10" LE on disk; YCG6's `36474359` becomes YG10's `30314759`).
- Two top-level cocg-style calls instead of one yo + one cocg: dxv_decompress_yg10 calls cocg twice, first on `tex_data` (Y + Alpha interleaved per the YG10 alpha-on-luma trick) and again on `ctex_data` (Co + Cg). YG10's Y plane is reorganized to interleave alpha 4×4 blocks alongside luma 4×4 blocks at full res.
- `op_size[3]` is the alpha opcode stream (full-res, same as op_size[0] Y).
- `pix_fmt=YUVA420P`, `tex_ratio_Y = 16` for YG10 (vs 8 for YCG6) because each "logical" Y block is now 16 bytes (BC4-luma + BC4-alpha).

### Encoder-discretion (encoders differ → GlEnc may pick)

- `moov` placement: end-of-file (Alley) vs front (AME). **GlEnc: end-of-file** (carries from Phase 2B).
- `udta` payload: minimal `©swr` (Alley) vs 5 KB XMP (AME). **GlEnc: minimal `©swr = "GlEnc <version>"`** (carries).
- Chunk grouping (`stsc`/`stco`): 4 chunks for both Alley and AME on YCG6 (different number from DXT1's 3 / DXT5's 6-8). **GlEnc: 1 chunk** (carries — playback-irrelevant).
- BC4 luma endpoint selection per 4×4 block: encoders differ from block 1 (only block 0 converges). **No spec mandate.** Phase 4A picks its own search strategy.
- BC4 chroma endpoint selection per 4×4 chroma block (= 8×8 source pixels): encoders differ from block 0 most frames; converge ~10-40% of the time per frame depending on content flatness. **No spec mandate.**
- LZ pass byte-level cgo opcode-stream content (which back-references at which positions): encoders differ. **No spec mandate.**
- Opcode emission per cgo step: see GlanceCore's `DXVHQCgoDecoder` for the 17-opcode alphabet. Choosing between them is an optimization problem with no closed-form answer.

---

## What this comparison does NOT tell us

- Whether Alley's BC4 luma endpoint search outperforms AME's for **natural video** (vs the synthetic testsrc2 corpus). Pass C did not include real motion content. Phase 4B should re-run a representative real-world corpus (e.g. ShroomiesKingdom from Pass B's secondary corpus) to characterize file-size ratios under realistic content.
- Whether the Huffman-only mode observation generalizes. Some degenerate inputs (constant-color frames, frames where cgo emits a flat opcode distribution) might trigger encoders to switch to raw or single-fill modes. Out-of-scope for Pass C.
- Whether Resolume Arena's playback pipeline applies the same YCoCg→RGB reverse transform as the FFmpeg `dxv` decoder. (Phase 4B's gate: drop GlEnc YCG6 output into Arena, layer with effects, compare to Alley YCG6 of the same source.)
- Per-pixel decode quality comparison (PSNR / SSIM / max-pixel-error per channel) between Alley and AME on the same source — deferred from Pass C to Phase 4B's validation harness.

---

## Open questions for Phase 4A

### Easier than expected

- **Stream-level container fields require no new code.** GlEnc's Phase 2B
  MOV writer is exactly correct for YCG6 (stsd, tkhd, stbl skeleton,
  moov/udta layout). Phase 4A's MOV-side change is one line: update
  `DXVFormat.frameTagBytes` mapping for `.ycg6` to `36 47 43 59` LE
  (likely already there per recon).
- **Both encoders agree on opcode count to within ~0.5%** despite
  emitting different bytes. The opcode COUNT is largely
  content-determined; the encoder's freedom is in *what each opcode is*
  + *how BC4 endpoints get picked*, not how many opcodes to emit.

### Harder than expected

- **Both reference encoders use Huffman exclusively** (180/180 = 100%
  observations). GlEnc's Phase 4A must implement Huffman-stream encoding
  (`fill_ltable` + `fill_optable` + `get_opcodes` reverse) — there's no
  FFmpeg encoder reference for this, so it's original work. Estimated
  ~200-300 lines of Swift. Reasonable plan: encode the byte-value
  frequency histogram from cgo's output, build a canonical Huffman tree
  (longest code last as required by `fill_ltable`'s decode side), emit
  the ltable + bitstream.
- **17-opcode cgo alphabet decision logic** is the dominant unknown.
  GlanceCore's `DXVHQCgoDecoder` is the spec for what each opcode MEANS;
  Phase 4A must make the per-block CHOICES. v0.4.0 baseline plan: emit
  the literal-pair opcode (op-0 in cgo's local numbering) for every
  pair of 4×4 blocks, achieving valid HQ output at sub-optimal bitrate;
  iterate from there in v0.4.1+.
- **BC4 endpoint search at production quality.** Single-channel block
  compression is well-understood but the search-quality dimension is
  encoder-discretion. Phase 4A can reuse Phase 3A's BC4 alpha endpoint
  search code (`BC4AlphaEncoder.swift`) — same mechanism, different
  input bytes. Need to verify whether the Phase 3A code is plane-
  agnostic enough to drop in.

### Surprising

- **testsrc2 HQ is only 1.27× DXT1**, not 5-10×. HQ's compression
  advantage on flat-color content is dramatic. Real motion-graphic
  content will likely shift this ratio significantly; **do not lock a
  Phase 4 file-size gate from testsrc2 alone.**
- **AME's YCG6 is SMALLER than Alley's** (-1.0% per frame), opposite of
  Pass B's DXT5 (AME +20.8% vs Alley). Encoder byte-efficiency rank
  varies per codec variant.
- **Both encoders agree on chunk grouping (4 chunks, 8+8+8+6)** for
  YCG6 — different from DXT1/DXT5 where they diverged on chunk count.
  Possibly coincidence on a single corpus; possibly a `pix_fmt`-derived
  default in one of the encoder libraries. Informational only —
  **GlEnc's 1-chunk-total convention from Phase 2B remains acceptable**.

---

## Notes on the analysis pipeline

- Atom walker + per-frame walker: in-line Python in the Pass C session
  log (see `git log` for the Phase 4A commit referencing Pass C).
- Opcode-stream byte-boundary simulator (`sim_fill_ltable` +
  `sim_get_opcodes`) is new for Pass C. It computes byte-consumption
  without doing full Huffman decode by leveraging the `size_in_bits`
  LE32 header read by `get_opcodes`. Verified: total bytes consumed by
  the simulator across (Y + Cocg) layouts equals the per-frame payload
  size exactly (+0 diff) for both Alley frame 1 and AME frame 1.
- Source corpus committed via Git LFS: `reference/ycg6/source/source.mov`
  (ProRes 4444), `frame_*.png` (30 PNGs), plus the two encoder outputs
  `alley.mov` and `ame.mov`.
- Decoded comparison frames NOT generated for Pass C (deferred to
  Phase 4B's validation harness). Both reference files are presumed
  Resolume-playable per the FFmpeg ffprobe success; no Pass C step
  attempts visual decode comparison.

---

End of Pass C findings. Planner reviews before commit + tag.
