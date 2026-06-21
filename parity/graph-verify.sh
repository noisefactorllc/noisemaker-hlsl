#!/usr/bin/env bash
# graph-verify.sh — GRAPH-parity harness.
#
# For every parity/programs/*.dsl (or the programs named as args), diff the graph the
# C# live DslCompiler produces against the reference export-graph.mjs oracle, byte-for-
# byte (structural). This is the graph-level analog of the pixel harness (see README):
#
#   DSL ─┬─ tools/export-graph.mjs ───────► <name>.ref.graph.json ─┐
#        └─ NMParityRunner.CompileDslDumpBatchFromCommandLine (Unity, one session)
#                                          └─ <name>.cs.graph.json ─┴─► graph-diff.py ─► PASS/FAIL
#
# It validates the C# DSL frontend (Compiler/) against the golden path with zero GPU
# work — fast, deterministic, and the thing the live-DSL path is "diffed against".
#
# Requires (env; no machine-specific paths are committed):
#   UNITY          path to the Unity editor binary
#   UNITY_PROJECT  path to a Unity project that embeds com.noisemaker.hlsl
#   NODE           node binary           (default: node)
#   PYTHON         python3 binary        (default: python3)
#
# Usage:
#   UNITY=/path/to/Unity UNITY_PROJECT=/path/to/proj ./parity/graph-verify.sh [program ...]
#   (program = a name like `noise` or a path to a .dsl; default = all parity/programs/*.dsl)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NODE="${NODE:-node}"
PYTHON="${PYTHON:-python3}"
: "${UNITY:?set UNITY to the Unity editor binary}"
: "${UNITY_PROJECT:?set UNITY_PROJECT to a Unity project that embeds com.noisemaker.hlsl}"

OUTDIR="$ROOT/parity/out/graph"
mkdir -p "$OUTDIR"
MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT

# Resolve the program list: args (names or paths) or all programs.
progs=()
if [ "$#" -gt 0 ]; then
  for a in "$@"; do
    if [ -f "$a" ]; then progs+=("$a"); else progs+=("$ROOT/parity/programs/$a.dsl"); fi
  done
else
  for f in "$ROOT"/parity/programs/*.dsl; do progs+=("$f"); done
fi

echo "=== 1/3  reference goldens (export-graph.mjs) ==="
for dsl in "${progs[@]}"; do
  name="$(basename "$dsl" .dsl)"
  if "$NODE" "$ROOT/tools/export-graph.mjs" --file "$dsl" "$OUTDIR/$name.ref.graph.json" >/dev/null; then
    printf '%s\t%s\n' "$dsl" "$OUTDIR/$name.cs.graph.json" >> "$MANIFEST"
  else
    echo "  [skip] $name: export-graph failed (reference cannot compile it)"
  fi
done

echo "=== 2/3  C# candidate graphs (one Unity session) ==="
"$UNITY" -batchmode -quit -projectPath "$UNITY_PROJECT" -logFile "$OUTDIR/graph-dump.log" \
  -executeMethod Noisemaker.Hlsl.Editor.NMParityRunner.CompileDslDumpBatchFromCommandLine \
  -nmManifest "$MANIFEST"

echo "=== 3/3  diff (C# live graph vs reference oracle) ==="
pass=0; fail=0
for dsl in "${progs[@]}"; do
  name="$(basename "$dsl" .dsl)"
  if "$PYTHON" "$ROOT/parity/graph-diff.py" \
       "$OUTDIR/$name.ref.graph.json" "$OUTDIR/$name.cs.graph.json" --name "$name"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
done

echo "================================================"
echo "graph-parity: $pass PASS, $fail FAIL / $((pass + fail))"
[ "$fail" -eq 0 ]
