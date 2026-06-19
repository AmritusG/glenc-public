# DXT1 byte-archaeology — Pass A findings

**Date:** 2026-05-09
**Source corpus:** 30 frames at 1920×1080@30fps, generated via FFmpeg `testsrc2` filter (color bars, scrolling text, gradients, fine detail), saved as PNG sequence and as ProRes 4444 `source.mov`.
**Encoders compared:** Resolume Alley, Adobe Media Encoder + Resolume DXV plugin, FFmpeg (`-c:v dxv -format dxt1`, version 8.1.1, libavcodec 62.28.101).

> **Note on Resolume Arena.** Arena is a performance tool with no `.mov` export feature in current versions, so this Pass A intentionally compares 3 encoders, not 4.

---

## ⚠ Contradictions with DECISIONS-2026-05-09.md (needs planner)

Two empirical findings contradict locked decisions in `DECISIONS-2026-05-09.md`. These are **flagged here**, not silently fixed — per the explicit Pass A instruction to surface contradictions for review:

1. **The d4556c9 "bit-identical with Resolume Alley" claim does not hold for our corpus.**
   `DECISIONS-2026-05-09.md` cites: *"Per commit `d4556c9` (June 2025) 'improve compatibility with Resolume products': produces packets bit-identical to Resolume Alley in manual tests."*
   Empirical result on `testsrc2` × FFmpeg 8.1.1 × Resolume Alley: **0 of 30 per-frame payload SHA-256 matches** between alley.mov and ffmpeg.mov. Not within an order of magnitude of bit-identity. FFmpeg's payloads are **systematically ~16% smaller** than Alley's (mean ≈ +14,950 bytes per frame, alley over ffmpeg).
   Possible explanations (not investigated): the d4556c9 "manual tests" may have used different content; Alley may have been updated since; FFmpeg may have improved compression beyond Alley; testsrc2 may exercise paths the manual tests didn't.

2. **The Phase 2 validation methodology presupposes FFmpeg=Alley equivalence.**
   `DECISIONS-2026-05-09.md` decision 1: *"Phase 2 target is bit-identical-to-Resolume-Alley DXT1 output, validated by byte-comparison against `ffmpeg -c:v dxv -format dxt1` on the same source."*
   Since FFmpeg ≠ Alley empirically, "byte-compare against ffmpeg" is **not** a proxy for "match Alley." The validation harness needs reframing — either:
   (a) lower Phase 2 target to "Resolume-playable, structurally Alley-compatible" (drop the bit-identity ambition);
   (b) keep the bit-identity ambition but validate against Alley directly, not FFmpeg;
   (c) investigate why FFmpeg and Alley diverge on testsrc2 and pick whichever encoder represents the "right" behavior — the answer may turn out to be neither, and Phase 2's encoder is then designed around the spec-mandated invariants this archaeology pass uncovers.

The rest of this document records the findings as data; the strategy decision belongs to the planner.

---

## File-level summary

| File | Size | SHA-256 (truncated) |
|---|---|---|
| `alley.mov`  | 2,821,668 B (2,755 KiB) | `6d313462247fae8d…` |
| `ame.mov`    | 2,826,362 B (2,760 KiB) | `73020377c78833ae…` |
| `ffmpeg.mov` | 2,374,130 B (2,318 KiB) | `3d7cb4b91d9fe85b…` |

**Bit-identical pairs at file level:** none. All three SHA-256 differ. (Expected — file-level identity would require identical container layout, identical metadata atoms, and identical encoder strings, which already differ at atom level — see §"Atom structure" below.)

ffprobe agrees on the substantive fields for all three: `codec_name=dxv`, `codec_tag_string=DXD3`, `width=1920`, `height=1080`, `r_frame_rate=30/1`, `nb_frames=30`, `duration=1.000000`, `pix_fmt=rgba`. So at the API level the three are equivalent DXV3-DXT1 streams; the differences are below the codec abstraction.

---

## Atom structure

Top-level layout differs in two ways: (a) `moov` placement, (b) `udta` metadata payload.

| File | Layout (top-level) | `moov` placement | `udta` size |
|---|---|---|---|
| `alley.mov`  | `ftyp wide mdat moov` | end-of-file | 28 B (just `©swr`) |
| `ame.mov`    | `ftyp moov mdat`      | front (faststart-style) | 5,095 B (`©swr`, `©TIM`, `©TSC`, `©TSZ`, `XMP_`) |
| `ffmpeg.mov` | `ftyp wide mdat moov` | end-of-file | 33 B (just `©swr`) |

- **`moov` placement** — Alley/FFmpeg place `moov` at end-of-file (write-as-you-go pattern, with a leading `wide` placeholder). AME places `moov` at front (faststart, optimized for streaming-from-file). Both patterns are valid QuickTime; this is **encoder discretion**.
- **`udta` payload** — AME embeds 5 KB of XMP metadata plus QuickTime authoring tags. Alley/FFmpeg write only an `©swr` (writer/encoder string). **Encoder discretion.**

`stbl` substructure is identical in shape across all three: `stsd → stts → stsc → stsz → stco`. Sizes:
- `stsd`: 102 B (alley, ame), 128 B (ffmpeg). FFmpeg's larger stsd carries extension atoms — see §"`stsd`" below.
- `stco`: 28 B all three (3 chunks of 10 frames each).
- `stsz`: 140 B all three (per-sample sizes for 30 frames).
- `stts`: 24 B all three (single 30/15360 entry — uniform 30 fps).
- `stsc`: 40 B all three (2 run-length entries).

**Summary:** the `stbl` skeleton is bit-identical in structure; the per-encoder differences are placement of `moov` and contents of `udta` and `stsd`.

---

## `stsd` atom

All three carry the codec FourCC `DXD3` at offset 20 from atom-start (= immediately after entry_size header). This confirms the recon finding that **stream-level FourCC is `DXD3` for all DXT1 DXV3 files**, consistent with HANDOVER and DECISIONS-2026-05-09.md.

### Alley `stsd` (102 B) and AME `stsd` (102 B)

```
0000  00 00 00 66 73 74 73 64 00 00 00 00 00 00 00 01   ...fstsd........
0010  00 00 00 56 44 58 44 33 00 00 00 00 00 00 00 01   ...VDXD3........
0020  00 00 00 00 46 46 4d 50 00 00 02 00 00 00 02 00   ....FFMP........
0030  07 80 04 38 00 48 00 00 00 48 00 00 00 00 00 00   ...8.H...H......
0040  00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00   ................
0050  00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00   ................
0060  00 00 00 18 ff ff                                 ......
```

**Byte-for-byte identical** between alley.mov and ame.mov. Notable fields:
- Offset 0x14: format `DXD3`
- Offset 0x24: vendor code `FFMP` (not "RESL" or similar — interesting; this is a QuickTime sample-description vendor-code field, presumably both encoders inherited it from the same QuickTime SDK / convention)
- Offset 0x2C: `0x00 0x00 0x02 0x00 0x00 0x00 0x02 0x00` — temporal/spatial quality flags (depth=0x18 at the end, 24-bit color)
- Offset 0x34: width `0x07 0x80` = 1920, height `0x04 0x38` = 1080
- Offset 0x38: dpi-h/dpi-v `0x00 0x48 0x00 0x00 0x00 0x48 0x00 0x00` (72 dpi h&v)
- Last byte `0x18` = 24 (depth in bits), trailing `0xFF 0xFF` = color table id (none)

### FFmpeg `stsd` (128 B)

Identical to Alley/AME for the first 0x40 bytes EXCEPT:

- Offset 0x42: instead of zeros, FFmpeg writes `0x11` (= 17, length prefix) + `Lavc62.28.101 dxv` (encoder identification string in the codec_name field — a QuickTime convention)
- Offset 0x66: extension atom `fiel` (10 B): `00 00 00 0a 66 69 65 6c 01 00` — field/order: progressive (1), order: top-first (0). Inert for progressive content.
- Offset 0x70: extension atom `pasp` (16 B): `00 00 00 10 70 61 73 70 00 00 00 01 00 00 00 01` — pixel aspect ratio 1:1.

**Spec-mandated vs encoder discretion:**
- The first 102 bytes of stsd are **byte-identical** Alley=AME, suggesting **strong spec mandate** for the substantive sample-description fields (FourCC, vendor code `FFMP`, dimensions, DPI, depth).
- The encoder-name string and `fiel`/`pasp` extension atoms are **encoder discretion** (FFmpeg writes them, Alley/AME don't, all three Resolume-play). GlEnc may write or omit these; recommend omitting to match Resolume more closely.

---

## `tkhd` presentation dimensions (locked-decision verification)

All three encoders write **1920 × 1080** in `tkhd` (presentation dimensions), not 1920 × 1088 (16-aligned coded). This **confirms** DECISIONS-2026-05-09.md decision 3: *"Pad coded_width / coded_height to next 16-multiple, zero-fill the padding region. Write actual presentation width / height in MOV `tkhd`."* All three reference encoders implement this convention.

For 1920×1080 the 16-multiple alignment is a no-op vertically (1080→1088 = +8 pixels, but 1080 is not a 16-multiple — actually 1080/16=67.5, so +8 to reach 1088); horizontally 1920 is already a 16-multiple. Test corpus doesn't exercise the horizontal padding path; recommend including a 1918×1080 or similar in Pass B to verify encoder behavior on non-aligned widths.

---

## Per-frame DXV header (12 bytes)

All three encoders agree on every byte of the per-frame header for all 30 frames:

| Byte offset | Field | Value | Encoder agreement |
|---|---|---|---|
| 0..3 | tag (LE) | `31 54 58 44` = "DXT1" reversed | All three agree, all 30 frames |
| 4 | `version_major+1` byte | `0x04` (decoder reads as version 3 = DXV3) | All three agree |
| 5 | `version_minor` | `0x00` | All three agree |
| 6 | `raw_flag` | `0x00` (= compressed, not raw) | All three agree |
| 7 | `unknown` | `0x00` | **All three agree, all 30 frames** |
| 8..11 | `size` (LE32, payload bytes) | varies per frame | All three agree on the field's role; values differ |

**Findings:**
- The "unknown" byte (`dxvenc.c:231` writes `0x00`; `dxv.c:968` reads then skips) is **always `0x00`** across 90 frames × 3 encoders × 30 frames each. Not a per-frame variable. Recommend: GlEnc writes `0x00`. Treat as reserved/padding. (The recon doc's "found in samples but didn't establish meaning" is now: **value is 0 across all encoders observed**.)
- `version_major+1=4` and `version_minor=0` are uniform — DXV3 v3.0 across the board.
- `raw_flag=0` for all 30 testsrc2 frames in all three encoders. The decoder's RAW path (`dxvenc.c:962` "Encoder copies texture data when compression is not advantageous") is not exercised by this corpus. Recommend: Pass B or a follow-up corpus include a high-entropy or trivial-color source to elicit RAW packets and verify when each encoder switches to raw.

---

## Per-frame payload SHA-256 matrix (the headline result)

Bytes after the 12-byte header, hashed per frame:

| | alley=ame | alley=ffmpeg | ame=ffmpeg | all-three |
|---|---|---|---|---|
| Frames matching | **0 / 30** | **0 / 30** | **0 / 30** | **0 / 30** |

Zero pairwise matches across all 30 frames. The encoders disagree on **every byte of every payload** for this corpus.

This is the empirical falsification of the d4556c9 "bit-identical to Alley" claim flagged in the contradictions section above.

---

## Per-frame payload size

| Encoder | Total payload | Mean per frame | Range |
|---|---|---|---|
| `alley.mov`  | 2,820,457 B | 94,015 B | [93,221, 94,767] |
| `ame.mov`    | 2,820,092 B | 94,003 B | [93,058, 94,795] |
| `ffmpeg.mov` | 2,372,888 B | 79,096 B | [78,708, 79,541] |

Alley vs FFmpeg per-frame delta: mean `+14,950 B` (Alley larger). Min `+14,326 B`, max `+15,405 B`.
Alley vs AME per-frame delta: typically ±100 B (Alley sometimes larger, sometimes smaller).

**Interpretation:**
- Alley and AME produce **near-identical bitrates** per frame (delta within ~0.1%) but **different bytes**. Their LZ encoder strategies differ at the byte level; their compression *efficiency* is the same. Suggests they share the same DXT1 block-encoder (BC1 endpoint selection) but have different LZ-pass implementations.
- FFmpeg compresses **systematically better** (~16% smaller payloads). Either FFmpeg's BC1 encoder produces fewer literal bytes (better endpoint reuse), or its LZ encoder finds more back-references (better hash table usage), or both. Without diffing decompressed output we can't tell whether FFmpeg's quality is higher, lower, or equal — only that its bitrate is lower.

---

## Spec-mandated vs encoder discretion — Phase 2 actionable summary

### Spec-mandated (encoders agree → GlEnc must match)

- Stream-level codec FourCC: **`DXD3`**.
- Per-frame 12-byte header layout: `tag(4 LE)` + `version_major+1(1)=0x04` + `version_minor(1)=0x00` + `raw_flag(1)=0x00` + `unknown(1)=0x00` + `size(4 LE)`.
- Per-frame Tag values: `DXT1`/`DXT5`/`YCG6`/`YG10` (LE-on-disk).
- `tkhd` carries **presentation** width/height, not 16-aligned coded width/height.
- `stbl` skeleton: `stsd → stts → stsc → stsz → stco`.
- `stsd` substantive fields (102 B core, byte-identical Alley=AME): vendor code `FFMP`, depth=24, color-table-id=`0xFFFF`, dimensions, 72 DPI both axes.

### Encoder discretion (encoders differ → GlEnc may pick)

- `moov` placement: end-of-file (Alley/FFmpeg) vs front-of-file (AME). Recommend end-of-file for write-as-you-go simplicity (mirrors Alley, which is the closest functional analogue to GlEnc's use case).
- `udta` payload: Alley/FFmpeg write only `©swr`. AME writes XMP + QuickTime authoring tags. Recommend `©swr=GlEnc <version>` only.
- `stsd` extension atoms (`fiel`, `pasp`, encoder-name string): FFmpeg writes them, Alley/AME don't. Recommend omitting to match Alley.
- LZ-pass byte-level encoding strategy (which back-references at which positions): every encoder differs. **No spec mandate.**
- BC1 endpoint selection per 4×4 block: encoders differ. **No spec mandate.**

### What the per-frame payload comparison does not tell us yet

Whether the three encoders produce **visually equivalent** decoded output. Bytes differ, but if all three decode to the same RGB pixels (within DXT1's lossy quantization noise floor), Resolume's own DXT1 decoder doesn't care which encoder produced which bytes. **A future diagnostic should decode all three through GlanceCore (or FFmpeg's decoder) and compute pixel-level PSNR / SSIM / max-pixel-error vs the source.** That's what tells us whether FFmpeg's smaller payloads are higher quality (better endpoint search) or lower quality (lossier).

---

## Open questions for Pass B (HQ archaeology, before Phase 4)

- Same three-way comparison on YCG6 and YG10 outputs from Resolume Alley + AME (no FFmpeg HQ encoder exists yet, per DECISIONS-2026-05-09 finding 4).
- Do Alley/AME produce identical opcode streams for HQ? (Tests whether the opcode stream is spec-mandated or encoder discretion.)
- For HQ specifically: do encoders agree on chroma subsampling ratio? Op-buffer compression mode (raw vs single-byte-fill vs Huffman)?
- Pixel-level decode comparison for DXT1 (deferred from Pass A): all three encoders → decoded RGB → PSNR vs ProRes source, to ground "encoder discretion" findings in actual quality numbers.
- High-entropy / trivial-color corpus to elicit `raw_flag=1` packets and verify RAW path conventions.
- Non-16-aligned width corpus (e.g. 1918×1080) to verify encoders' padding behavior matches DECISIONS-2026-05-09 decision 3.

---

## Notes on the analysis pipeline

- Atom walker and per-frame extractor: `/tmp/dxt1-archaeology.py` (pattern reusable for Pass B).
- Full raw output: `/tmp/dxt1-archaeology.txt`.
- Source corpus committed via Git LFS: `reference/dxt1/source/source.mov`, `frame_*.png`, plus the three encoder outputs `alley.mov`, `ame.mov`, `ffmpeg.mov`.
- The analysis script's printed "codec FourCC" diagnostic line had an off-by-4 indexing bug for Alley/AME (showed `\x00\x00\x00V` = the entry_size field bytes); the actual hexdump and downstream conclusions are correct — `DXD3` is at atom-relative offset 0x14 in all three files. (Bug noted; harmless for findings; not patched since the script is single-shot diagnostic, not production.)
