# The packaging kit (macOS)

Project-agnostic scripts that take a Rust app of the Glance family from `cargo build` to a
notarised, stapled DMG with its checksum and exactly one LaunchServices record, the way the Swift
apps' release scripts do it (`glance/scripts/{build,sign,notarize,make-dmg,ls-cleanup,install-from-dmg}.sh`,
read for C3; `docs/handoffs/c3-shell.md` DIAGNOSE 4). Proven on `glance-sample`
(`crates/glance-sample/bundle/app.conf`; results in `docs/06-C3-RESULTS.md` §5).

| Script | Does |
|---|---|
| `bundle.sh <conf>` | `cargo build --release --locked` for `aarch64-apple-darwin` and `x86_64-apple-darwin` at `MIN_MACOS`, `lipo` into one binary, `strip -S` (debug information out, the symbol table kept; refuses if any debug map entry is left), the `.app` assembled in `STAGE_DIR` with `Info.plist` filled from the template; **refuses** when `CFBundleVersion` ≠ `CFBundleShortVersionString` or the bundle id is not the conf's |
| `sign.sh <conf> [path]` | Developer ID, hardened runtime, secure timestamp, `entitlements.plist`; strict verify |
| `notarize.sh <conf> [path]` | `notarytool submit --keychain-profile NOTARY_PROFILE --wait`, refuses anything but Accepted (prints the log), `stapler staple` + `validate`, Gatekeeper |
| `dmg.sh <conf>` | UDZO image "`<APP_NAME> <VERSION>`" with the app and an `/Applications` link, file `<APP_NAME>-v<VERSION>.dmg`; signed, notarised, stapled; then `<dmg>.sha256` |
| `ls-cleanup.sh <conf>` | targeted `lsregister -u` of the staged copy and mounted `/Volumes/<APP_NAME>*` copies; exit 1 unless the one record left is `INSTALL_DIR/<APP_NAME>.app`; never a database rebuild |
| `install.sh <conf> [dmg]` | mount read-only, Gatekeeper, `ditto` into `INSTALL_DIR`, detach, Gatekeeper + staple check, `ls-cleanup.sh` |
| `release.sh <conf>` | bundle → sign → notarise → DMG → ls-cleanup |

Nothing is staged in or beside the project (`lib.sh` refuses such a `STAGE_DIR`). Identities,
team ids and certificate hashes are masked in everything the kit prints.

## The slots (`app.conf`, sourced by bash)

| Slot | Example (glance-sample) | Note |
|---|---|---|
| `APP_NAME` | `Glance Sample` | the bundle's name, the DMG's volume and file name |
| `BUNDLE_ID` | `com.amritus.glancecore.sample` | at the swap: the Swift twin's id (`com.amritus.glance`) |
| `EXECUTABLE` / `CARGO_PACKAGE` | `glance-sample` | the binary and its package |
| `REPO` | the repo root | |
| `INFO_PLIST` | `Info.plist` | template beside the conf; `@APP_NAME@ @BUNDLE_ID@ @EXECUTABLE@ @VERSION@ @MIN_MACOS@` are filled |
| `VERSION` | the workspace version | both plist version fields get it |
| `MIN_MACOS` | `14.0` | the Swift apps' floor |
| `NOTARY_PROFILE` | `amritus-notary` | a keychain profile its owner stored once (`xcrun notarytool store-credentials <name>`); never a password |
| `SIGN_IDENTITY` | `auto` | `auto` = the first "Developer ID Application" identity in the keychain |
| `INSTALL_DIR` | `/Applications` | the one place the app is registered |
| `STAGE_DIR` | `$TMPDIR/glance-kit/<bundle id>` | outside the project; the kit creates it and uses its physical path (`pwd -P`: `/var/folders/…` becomes `/private/var/folders/…`, the path LaunchServices records), so the conf needs no resolving of its own |
| `ICON` (optional) | — | an `.icns` beside the conf, copied to `Contents/Resources/AppIcon.icns` (`CFBundleIconFile` = `AppIcon`) |
| `ENTITLEMENTS` (optional) | the kit's `entitlements.plist` | Swift Glance's two keys: user-selected read-only files, app-scope bookmarks |

The Rust toolchain must have both macOS standard libraries (`KIT_TOOLCHAIN_BIN`; default: the one on
`PATH` when it has both, else rustup's stable). Homebrew's rustc has no x86_64 std.

## Adoption checklist (an app repo taking the kit)

1. Copy `tools/package/` (keep the timestamps: `cp -Rp` / `ditto`) and `.cargo/config.toml`
   (deployment target 14.0).
2. Write `<crate>/bundle/app.conf` and `Info.plist` from glance-sample's. At the swap the plist
   carries the Swift app's document types and handler ranks exactly (Glance: one `QuickTime Movie`
   type, role Viewer, rank **Default**, `public.movie`, `com.apple.quicktime-movie`,
   `public.mpeg-4`, `public.avi`); a rehearsal or throw-away id uses rank **Alternate** so it never
   becomes the default for anyone's files.
3. The icon: the Swift app's `assets/<App>.icns`, as `ICON`.
4. `release.sh app.conf`, then `install.sh app.conf` on the build machine; the result must end with
   "OK: exactly one record".
5. Publishing (the app's releases repo, tag `v<version>`, the DMG and its `.sha256`, notes) is the
   app's own release step, not the kit's.
6. Windows: not in this kit (MSIX / installer and Artifact Signing come with the Windows milestone,
   C4).
