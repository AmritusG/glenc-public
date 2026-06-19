# Third-Party Notices

GlEnc's own source is licensed under the MIT License (see `LICENSE`). Some
source files are ports of, or derived from, or clean-room implementations
guided by, third-party projects. Each such file declares its license via an
`SPDX-License-Identifier` header. This document catalogues the upstream
provenance for attribution. It covers both GlEnc's own encoder-side source and
the **vendored** GlanceCore / GlancePlayback libraries (see the "Vendored
libraries" section at the end).

---

## LGPL-2.1-or-later — FFmpeg DXV ports/derivations

**Files:**
- `Sources/GlEncCore/DXVLZWriter.swift`
- `Sources/GlEncCore/DXVHQOpcodeWriter.swift`
- `Sources/GlEncCore/DXVHQCgoWriter.swift`

**Upstream project:** FFmpeg — `libavcodec/dxvenc.c` and `libavcodec/dxv.c`.

**Original copyright:**
- `dxvenc.c` (DXT1 compress reference): Copyright (C) 2024 Emma Worley.
- `dxv.c` (DXT5 LZ / opcode / cgo decode semantics): Copyright (C) 2015
  Vittorio Giovara; Copyright (C) 2018 Paul B Mahol.

**Upstream license:** LGPL-2.1-or-later (`LICENSES/LGPL-2.1.txt`).

**Note:** `DXVLZWriter.compressDXT1` is a faithful Swift port of `dxvenc.c`
(`dxv_compress_dxt1` + the `PUSH_OP` macro). `compressDXT5` and the two
`DXVHQ*Writer` files are encoder-side derivations written by reading the
corresponding `dxv.c` decoder routines (`dxv_decompress_dxt5`,
`dxv_decompress_opcodes`, `dxv_decompress_cgo`). All three preserve the
upstream LGPL-2.1-or-later license.

---

## MIT — BC1 endpoint search (FFmpeg texturedspenc.c)

**File:** `Sources/GlEncCore/BC1BlockEncoder.swift`

**Upstream project:** FFmpeg — `libavcodec/texturedspenc.c`.

**Original copyright:** Copyright (C) 2015 Vittorio Giovara, based on
public-domain code by Fabian Giesen, Sean Barrett, and Yann Collet.

**Upstream license:** MIT (per the `texturedspenc.c` header) — `LICENSES/MIT.txt`.

**Note:** Faithful Swift port of `compress_color` and its helpers
(`constant_color`, `optimize_colors`, `match_colors`, `refine_colors`, plus the
`expand5/6` / `match5/6` lookup tables).

---

## MIT — clean-room block-encoder refinements

**Files:**
- `Sources/GlEncCore/BC1BlockEncoderClusterFit.swift`
- `Sources/GlEncCore/BC4AlphaBlockEncoderRefined.swift`

**Upstream references:**
- libsquish (Simon Brown / Ignacio Castaño) — ClusterFit BC1 endpoint search.
- `rgbcx` / `bc7enc_rdo` (Rich Geldreich) — BC4 endpoint refinement.

**Upstream license:** MIT (libsquish); MIT or Public Domain (rgbcx/bc7enc_rdo)
— `LICENSES/MIT.txt`.

**Note:** These are clean-room Swift implementations written from the algorithm
descriptions; algorithms are not copyrightable. Attribution is provided as a
courtesy.

---

## BSD-3-Clause — Snappy compression format

**File:** `Sources/GlEncCore/SnappyCompressor.swift`

**Upstream project:** Google Snappy (compression format / reference C
implementation `snappy-c`).

**Original copyright:** Copyright (c) 2011, Google Inc.

**Upstream license:** 3-Clause BSD (`LICENSES/BSD-3-Clause.txt`).

**Note:** A from-scratch Swift implementation whose output is byte-compatible
with the Snappy format. The format/algorithm reference is Google's BSD-3
licensed snappy.

---

## HAP format — spec implementation

**Files:**
- `Sources/GlEncCore/HAPSection.swift`
- `Sources/GlEncCore/Hap1Encoder.swift`
- `Sources/GlEncCore/Hap5Encoder.swift`
- `Sources/GlEncCore/HapYEncoder.swift`
- `Sources/GlEncCore/HapAEncoder.swift`
- `Sources/GlEncCore/HapMEncoder.swift`
- `Sources/GlEncCore/HapYBlockPacker.swift`
- `Sources/GlEncCore/HapABlockPacker.swift`
- `Sources/GlEncCore/HapFrameEncoder.swift`

**Upstream references:**
- Vidvox HAP video specification
  (https://github.com/Vidvox/hap/blob/master/documentation/HapVideoDRAFT.md).
- Castaño & van Waveren, *Real-Time YCoCg-DXT Compression* (2007) — the
  scaled-YCoCg transform used by HapY/HapM.

**License:** GlEnc-original implementations of a published format spec, licensed
under MIT (`LICENSES/MIT.txt`). The Vidvox HAP reference implementation is itself
distributed under a permissive (BSD-style) license; the academic paper describes
an algorithm (not copyrightable). Attribution is provided for provenance.

---

All other files under `Sources/` are GlEnc original work under the MIT License,
including files that merely *call* the LGPL-licensed DXV writers — invoking
LGPL code does not place the caller under the LGPL.

---

# Vendored libraries — GlanceCore + GlancePlayback

`Sources/GlanceCore/` (15 files) and `Sources/GlancePlayback/` (4 files) are
vendored **from AmritusG/glance @ e134a3a (v0.7.0)** — GlEnc's prior pinned,
byte-gate-validated revision. Most files are MIT (glance-original / open-spec
implementations). The exceptions, distinct from GlEnc's own encoder-side DXV
ports above, are the decoder-side ports below.

## LGPL-2.1-or-later — FFmpeg DXV *decoder* ports (vendored)

**Files:**
- `Sources/GlanceCore/DXVPacketDecoder.swift`
- `Sources/GlanceCore/DXVHQCgoDecoder.swift`
- `Sources/GlanceCore/DXVHQOpcodeDecoder.swift`

**Upstream project:** FFmpeg — `libavcodec/dxv.c`.

**Original copyright:** Copyright (C) 2015 Vittorio Giovara
<vittorio.giovara@gmail.com>; Copyright (C) 2018 Paul B Mahol <onemda@gmail.com>.

**Upstream license:** LGPL-2.1-or-later (`LICENSES/LGPL-2.1.txt`).

**Note:** Faithful Swift ports of the DXV *decoder* routines
(`dxv_decompress_dxt1`/`dxt5`, `dxv_decompress_opcodes`, `dxv_decompress_cgo`/
`yo`). These are the decode counterparts to GlEnc's own encoder-side dxv ports;
they inherit the same LGPL-2.1-or-later license. Vendored from
AmritusG/glance @ e134a3a (v0.7.0).

## BSD-2-Clause — liblzf port (vendored)

**File:** `Sources/GlanceCore/DXV1PacketDecoder.swift`

**Upstream project:** liblzf (LZF decompressor).

**Original copyright:** Copyright (c) Marc Alexander Lehmann
<schmorp@schmorp.de>.

**Upstream license:** liblzf is dual-licensed BSD-2-Clause / GPL-2.0-or-later;
this file **elects BSD-2-Clause** (`LICENSES/BSD-2-Clause.txt`). The 4-byte
DXV1/DXV2 header parser additionally follows FFmpeg's `libavcodec/dxv.c`; the
file as published is BSD-2-Clause. Vendored from AmritusG/glance @ e134a3a
(v0.7.0).

## MIT — vendored GlanceCore / GlancePlayback (the other 15)

The remaining vendored files (BC4BC5Unpack, CPURender, DXVDemuxer, DXVDetector,
DXVHQDecoder, DXVThumbnail, HAPDemuxer, HAPDetector, HAPHQDecoder,
HAPPacketDecoder, HAPThumbnail; and GlancePlayback's DXVPlayer, DXVRenderer,
FrameClock, HAPPlayer) are MIT — glance-original code and open-spec (DXV / HAP /
BC4-BC5) implementations. Vendored from AmritusG/glance @ e134a3a (v0.7.0).
