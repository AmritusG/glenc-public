# Third-Party Notices

GlEnc's own source is licensed under the MIT License (see `LICENSE`). Some
source files are ports of, or derived from, or clean-room implementations
guided by, third-party projects. Each such file declares its license via an
`SPDX-License-Identifier` header. This document catalogues the upstream
provenance for attribution, and the licences of GlEnc's package dependencies
(see "Dependencies" at the end).

Since v1.4.0 nothing in GlEnc or its dependency graph is LGPL / GPL: DXV is
encoded and read by DXVKit (clean-room, MIT), the FFmpeg-derived DXV writers
and the vendored GlanceCore / GlancePlayback copy (with its FFmpeg dxv.c
decoder ports) are gone. Every licence in the graph is MIT, BSD or Apache-2.0.

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

**File:** `Sources/GlEncCore/BC4AlphaBlockEncoderRefined.swift`

**Upstream reference:** `rgbcx` / `bc7enc_rdo` (Rich Geldreich) — BC4 endpoint
refinement.

**Upstream license:** MIT or Public Domain (rgbcx/bc7enc_rdo) — `LICENSES/MIT.txt`.

**Note:** A clean-room Swift implementation written from the algorithm
description; algorithms are not copyrightable. Attribution is provided as a
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

All other files under `Sources/` are GlEnc original work under the MIT License.

---

# Dependencies (SwiftPM, resolved in Package.resolved)

| Package | Pin | Licence | Used for |
|---|---|---|---|
| AmritusG/dxvkit (DXVKit) | exact 1.0.0 | MIT | DXV3 encoding (all four variants) and DXV source reading |
| AmritusG/glance (GlanceCore, GlancePlayback) | exact 0.17.3 | MIT; its vendored C Snappy (`SnappyC`, from andikleen/snappy-c) is BSD-3-Clause; its `DXV1PacketDecoder` (liblzf port) is BSD-2-Clause | HAP source decoding, DXV / HAP detection, the preview player |
| apple/swift-argument-parser | from 1.3.0 | Apache-2.0 | `glenc-cli` argument parsing only |

GlEnc v1.3.0 and earlier also depended on lovetodream/swift-snappy (BSD-3,
via an AmritusG fork) as a test oracle; v1.4.0 drops it (its `SnappyC` target
collides by name with Glance's) and the tests carry their own Snappy decoder
(`Tests/GlEncTests/SnappyDecodeOracle.swift`, written from Google's format
description).

---

# In this public mirror

DXVKit 1.0.0 (`Sources/CDXVKit`, `Sources/DXVKit`; MIT, `LICENSES/DXVKit-LICENSE.txt`) and
Glance 0.17.3's GlanceCore, GlancePlayback and SnappyC (`Sources/GlanceCore`,
`Sources/GlancePlayback`, `Sources/SnappyC`; MIT, `LICENSES/Glance-LICENSE.txt`; SnappyC
BSD-3-Clause, `Sources/SnappyC/LICENSE`; GlanceCore's `DXV1PacketDecoder.swift` BSD-2-Clause,
`LICENSES/BSD-2-Clause.txt`) are copied in as source, unchanged from those tagged releases,
because their repositories are not public. Per-file licences are in the SPDX headers.
