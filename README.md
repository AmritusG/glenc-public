# GlEnc

**GlEnc** is a native macOS encoder for Resolume VJ workflows. Drop in any source video and encode it to the
formats Resolume and other realtime tools prefer, including Resolume **DXV3** output, with a queue-based window,
per-job trim / crop / resize / rename, a live preview and audio pass-through.

Version **1.7.0**, rebuilt in Rust (egui + wgpu). Requires **macOS 14 (Sonoma) or later**. Versions up to 1.6.2 were
Swift; their source is in this repository's history (tags `v1.1.0` … `v1.6.2`).

## Download

Prefer a ready-to-run app over building from source? Download the signed, notarised macOS DMG from
[glenc-releases](https://github.com/AmritusG/glenc-releases/releases/tag/v1.7.0).

## Formats

| Family | Variants | Notes |
|---|---|---|
| **DXV3** | DXT1, DXT5, YCG6 (HQ), YG10 (HQ + alpha) | Byte-identical to GlEnc 1.6.2's output (from every source but HAP Q) |
| **HAP** | Hap1, Hap5, HapY, HapM, HapA | Chunked or single, as 1.6.2 |
| **ProRes** | 422, 422 HQ, LT, Proxy, 4444 | 4444 carries source alpha through |
| **H.264 / HEVC** | — | `.mp4` / `.mov` |
| **Motion JPEG** | — | |

Audio tracks are carried through to formats that support them. Sources may themselves be DXV, HAP, ProRes,
H.264 / HEVC or Motion JPEG.

## Building

A Cargo workspace; everything it needs is public:

- [glance-core](https://github.com/AmritusG/glance-core) (MIT), the Glance family's shared core, pinned by tag;
- [DXVKit Plus](https://github.com/AmritusG/DXVKit-Plus) (MIT), every decoder and encoder, through glance-core;
- crates from crates.io, all permissive (MIT, Apache-2.0, BSD, Zlib, ISC), checked by `cargo deny check` (`deny.toml`).

```sh
cargo build --release            # target/release/GlEnc (the app) and target/release/glenc-cli
cargo run --release --bin GlEnc  # run the app unbundled
```

Rust 1.95 or newer. No FFmpeg, libav or GStreamer.

### App bundle and release builds (your own credentials)

`tools/package/` builds, signs, notarises and packs the app from `crates/glenc/bundle/app.conf`
(`tools/package/README.md` says what each step does):

```sh
tools/package/release.sh crates/glenc/bundle/app.conf
```

Signing and notarisation need **your own** Apple Developer credentials; none are in this repository. Set
`SIGN_IDENTITY` (or leave `auto`: the first "Developer ID Application" identity in your keychain) and
`NOTARY_PROFILE` (a notarytool keychain profile you store once with `xcrun notarytool store-credentials <name>`)
in `app.conf`, and change `BUNDLE_ID` if you ship your own build.

## This repository

A public mirror of GlEnc's source: the code and the build kit only. The tests, their media and the development
notes stay in the private working repository.

### Rules

No build-machine path or account name ever enters a public repo or a released binary: no /Users/<name>, no ~/ expanded, no /private/var/folders, no /Volumes/<private>, no host names, no session URLs. Logs, test output and data files are scrubbed or kept out of git. This is enforced by the pre-push hook, the CI path check and the kit's binary check; none of them may be bypassed, disabled or weakened (no --no-verify, no allow-list for a real path). A hit is fixed at the source, never waved through.

The machinery is `tools/path-guard.sh` (the Glance family's guard, kept in
[glance-core](https://github.com/AmritusG/glance-core) and copied here unchanged): the pre-push hook
(`tools/path-guard.sh install`, once per clone), a gate (`tools/path-guard.sh check`) and the `path-guard` CI job, a
required check on `main`. `tools/push-main.sh` is how a commit reaches `main` (through `guard/<sha>` and that job).

## License

MIT (`LICENSE`), Copyright (c) 2026 Amrit Rosell.
