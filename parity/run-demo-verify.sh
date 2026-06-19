#!/usr/bin/env bash
# run-demo-verify.sh — end-to-end demo-default parity verification.
#   1. golden (GLSL/webgl2) for every generated DSL
#   2. C#-DSL-compiler render via Unity (RenderDslBatchFromCommandLine) in /tmp/nmverify-proj
#   3. batch compare
# Generated DSLs + manifest.tsv must already exist in /tmp/demo (from gen-demo-dsl.mjs).
set -u
export PATH=$HOME/.local/node/bin:$PATH
UNITY=/Applications/Unity/Hub/Editor/6000.3.16f1/Unity.app/Contents/MacOS/Unity
PROJ=/tmp/nmverify-proj
ROOT=/Users/alex/source/noisemaker-unity
DEMO=/tmp/demo
GOLD=$DEMO/gold
OUT=$DEMO/out
mkdir -p "$GOLD" "$OUT"

# 1. Golden generation: batch-golden wants "<name>\t<dslPath>" — manifest.tsv already is that.
echo "=== [1/3] golden generation ==="
SHADE_HEADLESS=1 node "$ROOT/parity/batch-golden.mjs" "$DEMO/manifest.tsv" "$GOLD" \
  --size 256 --time 0.25 --backend webgl2 >"$DEMO/golden.out.log" 2>"$DEMO/golden.err.log"
echo "golden exit $?; goldens: $(ls "$GOLD"/*.golden.png 2>/dev/null | wc -l)"

# 2. Build the C#-DSL render manifest: "<dslPath>\t<outPng>"
awk -F'\t' -v out="$OUT" '{print $2"\t"out"/"$1".png"}' "$DEMO/manifest.tsv" > "$DEMO/render.tsv"
echo "=== [2/3] Unity C#-DSL render ==="
"$UNITY" -batchmode -quit -projectPath "$PROJ" \
  -logFile "$DEMO/unity.log" \
  -executeMethod Noisemaker.Hlsl.Editor.NMParityRunner.RenderDslBatchFromCommandLine \
  -nmManifest "$DEMO/render.tsv" -nmSize 256 -nmTime 0.25
echo "unity exit $?; candidates: $(ls "$OUT"/*.png 2>/dev/null | wc -l)"

# 3. Compare
echo "=== [3/3] compare ==="
python3 "$ROOT/parity/batch-compare.py" "$GOLD" "$OUT" --out "$DEMO/report.json"
