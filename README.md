# GlEnc

**GlEnc** is a native macOS encoder for Resolume VJ workflows. Drop in any
source video and encode it to the formats Resolume and other realtime tools
prefer — including byte-accurate Resolume **DXV3** output — with a queue-based
GUI, per-job trim/crop/resize/rename, live preview, and audio pass-through.

Version **1.1.0**. Requires **macOS 14 (Sonoma) or later**.

## Download

Prefer a ready-to-run app over building from source? Download the signed, notarized macOS DMG from [glenc-releases](https://github.com/AmritusG/glenc-releases).

## Formats

| Family | Variants | Notes |
|---|---|---|
| **DXV3** | DXT1, DXT5, YCG6 (HQ), YG10 (HQ + alpha) | Hand-rolled MOV writer; DXT1 output is byte-identical to FFmpeg's `dxv` encoder |
| **HAP** | Hap1, Hap5, HapY, HapM (HAP + alpha) | From-scratch Snappy + HAP section writer |
| **ProRes** | 422, 422 HQ, LT, Proxy, 4444 | 4444 carries source alpha through |
| **H.264 / HEVC** | — | VideoToolbox; rate-control, keyframe interval, profile; `.mp4`/`.mov` |
| **MJPEG** | — | (codec scaffolding present) |

Audio tracks are carried through to formats that support them. Source clips may
themselves be DXV3, HAP, ProRes, H.264/HEVC, or MJPEG.

## Building

GlEnc is a Swift Package (SwiftPM), pure Swift, no Xcode project required.

```bash
swift build -c release        # build the library + app target
swift run GlEnc               # run the app directly
```

Or use the bundled scripts to produce a proper `.app` bundle:

```bash
scripts/build.sh              # builds ./GlEnc.app (unsigned)
scripts/run.sh                # build + launch
```

> **Cmd-Tab icon note:** macOS only renders a custom app icon at Cmd-Tab for
> bundles under `/Applications`. `scripts/install.sh` copies the build there and
> re-registers it. Running from the repo is fine for development; the icon just
> shows a placeholder at Cmd-Tab.

### Release builds (signing & notarization — you supply your own credentials)

The release pipeline is `build.sh` → `sign.sh` → `notarize.sh` → `make-dmg.sh`.
These require **your own** Apple Developer credentials — none are bundled:

- Export your Developer ID signing identity before signing/DMG steps:
  ```bash
  export SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
  ```
  (`security find-identity -v -p codesigning` lists yours.)
- `notarize.sh` uses a notarytool **keychain profile** you create once with
  `xcrun notarytool store-credentials <profile-name>` (your Apple ID, team ID,
  and an app-specific password). Point the script at your profile name.

## Testing

```bash
swift test
```

The test suite includes a DXV3 **byte-identity gate** (GlEnc's DXT1 MOV output
is compared atom-by-atom and `mdat`-byte-equal against reference encoder
outputs). A few small reference fixtures ship in `reference/`; the bulk of the
corpus is regenerable or local-only and tests **skip cleanly** when a fixture is
absent.

- `scripts/make-corpus.sh` regenerates the deterministic synthetic corpus (and,
  if FFmpeg is installed, the `testsrc2` source corpus).
- See [`reference/README.md`](./reference/README.md) for the full fixture story:
  what ships, what needs FFmpeg (version-pinned), what needs Resolume
  (unscriptable), and what is local-only.

## License

GlEnc's own source is released under the **MIT License** (see [`LICENSE`](./LICENSE)).

Some files carry other terms, declared per-file via `SPDX-License-Identifier`
headers:

- The DXV3 LZ / opcode / cgo writers are Swift ports/derivations of FFmpeg's
  `dxvenc.c` / `dxv.c` and are **LGPL-2.1-or-later**.
- The Snappy compressor is **BSD-3-Clause**.
- Other ported / clean-room files retain upstream **MIT** attribution.

Full upstream attribution is in
[`THIRD-PARTY-NOTICES.md`](./THIRD-PARTY-NOTICES.md); license texts are in
[`LICENSES/`](./LICENSES).
