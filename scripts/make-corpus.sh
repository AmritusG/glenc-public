#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> GlEnc corpus regenerator"
echo "    Repo root: $ROOT"
echo ""

echo "==> [1/3] Synthetic stress corpus (deterministic, no external tools)"
echo "    Regenerating reference/synthetic-corpus/source/ via the env-gated generator."
GLENC_GEN_SYNTHETIC=1 swift test -c release \
    --filter "CorpusGenerationTests/testGenerateSyntheticCorpus"
echo "    Done: 12 CoreGraphics-drawn PNGs, byte-for-byte reproducible."
echo ""

echo "==> [2/3] testsrc2 source corpora (require FFmpeg)"
if command -v ffmpeg >/dev/null 2>&1; then
    FFVER="$(ffmpeg -version 2>/dev/null | head -1)"
    echo "    FFmpeg found: $FFVER"
    echo "    Regenerating reference/dxt1/source/ (1920x1080@30, 30 frames)."
    mkdir -p reference/dxt1/source
    ffmpeg -y -f lavfi -i "testsrc2=size=1920x1080:rate=30" -frames:v 30 \
        -c:v prores_ks -profile:v 4444 reference/dxt1/source/source.mov
    ffmpeg -y -i reference/dxt1/source/source.mov \
        -start_number 1 reference/dxt1/source/frame_%04d.png
    echo "    Done: reference/dxt1/source/source.mov + frame_0001..0030.png"
    echo "    NOTE: dxt5/ycg6/yg10 source corpora overlay a synthesized alpha mask"
    echo "          on testsrc2 (see each reference/<variant>/FINDINGS.md). Regenerate"
    echo "          those from the per-variant FINDINGS commands if you need them."
else
    echo "    FFmpeg NOT found on PATH. Skipping testsrc2 regeneration."
    echo "    To regenerate the DXT1 source corpus, install FFmpeg and run:"
    echo "      ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30 -frames:v 30 \\"
    echo "          -c:v prores_ks -profile:v 4444 reference/dxt1/source/source.mov"
    echo "      ffmpeg -i reference/dxt1/source/source.mov \\"
    echo "          -start_number 1 reference/dxt1/source/frame_%04d.png"
fi
echo ""

echo "==> [3/3] Oracle fixtures (NOT regenerable here — they SHIP in-repo)"
echo "    reference/dxt1/ffmpeg.mov is BYTE-IDENTITY-LOCKED to FFmpeg 8.1.1 /"
echo "      libavcodec 62.28.101 (-c:v dxv -format dxt1). A different FFmpeg"
echo "      build will NOT reproduce its bytes, so the byte gate ships it verbatim."
echo "    reference/dxt1/alley.mov is IRREPRODUCIBLE by script: it is a Resolume"
echo "      Alley export (proprietary GUI, no headless/CLI path). It ships verbatim."
echo "    This script never attempts to produce either oracle."
echo ""

echo "==> Local-only real-world corpora (require source clips you must supply)"
SRC_CLIP="${1:-}"
if [ -n "$SRC_CLIP" ]; then
    if [ -f "$SRC_CLIP" ]; then
        echo "    Source clip provided: $SRC_CLIP"
        echo "    Regenerating reference/realworld-corpus/ from it."
        GLENC_GEN_REALWORLD=1 GLENC_REALWORLD_SRC="$SRC_CLIP" swift test -c release \
            --filter "CorpusGenerationTests/testGenerateRealworldCorpus"
        echo "    Done. (yg10 / dxt5-paired corpora need their own paired DXV clips;"
        echo "     see reference/CORPUS-METHODOLOGY.md for those generators.)"
    else
        echo "    Provided path does not exist: $SRC_CLIP — skipping real-world corpus."
    fi
else
    echo "    No source-clip argument given — skipping real-world corpus regeneration."
    echo "    Usage: scripts/make-corpus.sh [/path/to/source-clip.mov]"
    echo "    These corpora are decoded from local-only DXV3 clips and are not"
    echo "    required for the byte gate; tests that need them skip cleanly when absent."
fi
echo ""

echo "==> Corpus regeneration pass complete."
