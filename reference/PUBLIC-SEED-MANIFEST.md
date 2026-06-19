# Public-seed keep/strip manifest

This is the explicit keep/strip list the **future public-seed step** will follow
when seeding a fresh public repo from a cleaned snapshot of this tree. It is a
plan only — **this document deletes nothing**, and the strip happens at seed
time, not in the private tree.

Rationale established by the regenerability diagnosis: only **DXT1** has a true
byte-identity-to-oracle gate; its only irreplaceable oracles are `ffmpeg.mov`
(~2.37 MB, FFmpeg-version-locked) and `alley.mov` (~2.82 MB, Resolume Alley,
unscriptable). DXT5/YCG6/YG10 are SSIM-measured, not byte gates. The ~940 MB
remainder is regenerable, GlEnc-produced, or local-only real media.

## KEEP (ships in the public seed)

- `reference/dxt1/ffmpeg.mov` — DXT1 byte-gate oracle (FFmpeg 8.1.1 / libavcodec 62.28.101).
- `reference/dxt1/alley.mov` — DXT1 byte-gate oracle (Resolume Alley export).
- `reference/dxt1/source/frame_0001..0030.png` — byte-gate encoder inputs.
- `reference/**/FINDINGS.md`, `reference/**/PHASE-*-RESULTS.md`,
  `reference/CORPUS-METHODOLOGY.md`, `reference/README.md`,
  `reference/PUBLIC-SEED-MANIFEST.md`, `reference/endpoint-search-study/FINDINGS.md`
  — byte-archaeology documentation.
- `reference/synthetic-corpus/` — optional; tiny and deterministic. May ship as a
  baseline or be left to `scripts/make-corpus.sh`. (Tests skip if absent.)
- `scripts/make-corpus.sh` + the env-gated generators in
  `Tests/GlEncTests/CorpusGenerationTests.swift`.

## STRIP (removed at seed time — ~940 MB)

Regenerable / GlEnc-produced / local-only media:
- `reference/dxt1/source/source.mov` (regenerable testsrc2 ProRes 4444).
- `reference/dxt1/glenc.mov`, `reference/dxt1/ame.mov` (GlEnc output / unused archival oracle).
- `reference/dxt5/**`, `reference/ycg6/**`, `reference/yg10/**` EXCEPT their `FINDINGS.md` /
  `PHASE-*-RESULTS.md` (strip source PNGs, source.mov, alley.mov, ame.mov, glenc.mov,
  realworld-source/realworld-*.mov).
- `reference/realworld-corpus/`, `reference/realworld-yg10-corpus/`,
  `reference/realworld-dxt5-paired-corpus/` (local-only 4K PNG corpora).
- `reference/dxdi/sample.mov`, `reference/hap-source/`, `reference/hap-audio/`,
  `reference/hapm/`, `reference/fps/*.mp4` (local-only / derived media).
- `reference/PHASE-8A-SURVEY.md`, `reference/PHASE-8B-FILE-HANDLES.md` — internal
  phase-survey notes (NOT `FINDINGS.md` / `PHASE-*-RESULTS.md` archaeology, which
  are KEEP). Removed from the working repo as of the path-genericization pass.

Private CC-workflow material (strip from the seed; not under `reference/`):
- `CLAUDE.md`, `CC_PROGRESS_LOG.md`, `HANDOVER.md`.
- Planner notes: `CROP_PLAN.md`, `CROP_RESIZE_PLAN.md`, `RESIZE_PLAN.md`,
  `HAP_PLAN.md`, `HAP2_PLAN.md`, `HAPM_PLAN.md`, `HAP_OUTPUT_PLAN.md`, `PIN_BUMP_PLAN.md`.
- Dated decision/phase logs: `DECISIONS-2026-05-09.md` and the `-PassA/-PassB/-PassD`
  variants. (The per-variant `reference/**/FINDINGS.md` archaeology docs are KEEP.)
- `GlEnc-AlphaPreview-Lessons.md` — sibling-facing reference; **flagged for the
  author's decision**, default strip.

## Notes for the seed step

- Stripping a file from the tree does NOT remove it from history — the seed must
  be a **fresh repo with new history**, not a tree-clean of this repo.
- A LICENSE + third-party attribution (FFmpeg LGPL ports, etc.) must be added to
  the seed; it does not exist in this tree.
- After strip, every test consuming a stripped fixture skips cleanly (see
  `reference/README.md`); the byte gate stays green because its KEEP fixtures ship.
