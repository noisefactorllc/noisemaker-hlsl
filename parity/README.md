# noisemaker-hlsl — Parity Harness

End-to-end pixel-parity verification: render the same DSL program with the **JS
reference engine** (golden) and the **Unity/HLSL port** (candidate), then diff.

This is how every ported piece gets validated — the package is built
correct-by-construction and is not pixel-verified until this harness runs (see
`../ARCHITECTURE.md` → "Validation").

```
  DSL ─┬─► tools/export-graph.mjs ───────────► graph.json ─┐
       │                                                    ├─► NMParityRunner.cs ─► candidate.png ─┐
       └─► parity/export-and-render.mjs ─► golden.png ──────┘ (Unity, batchmode)                    ├─► compare.py ─► PASS/FAIL
                              (reference GPU, Playwright)                                            │
                                                                          golden.png ───────────────┘
```

## Prerequisites

- **Node** (for `tools/` and `parity/*.mjs`). No `npm install` needed — the
  scripts import the sibling reference engine (`../../noisemaker/shaders`,
  `../../noisemaker/demo`) as plain ESM and the PNG encoder uses Node's built-in `zlib`.
- **Playwright + a system Chrome.** `export-and-render.mjs` launches Chromium via
  the vendored `shade-mcp` harness (`../../vendor/shade-mcp/harness`). On macOS it
  uses ANGLE/Metal; headless by default (`SHADE_HEADLESS=1`).
- **Python 3** with `numpy` + `pillow` (for `compare.py`) — same deps as
  `../../scripts/image_regression.py`.
- **A Unity project** (2021.3+, **Linear color space**) that includes the package
  `com.noisemaker.hlsl`.

All scripts honor `NM_REFERENCE_ROOT` to relocate the reference repo root
(default: two levels above `tools/`).

## Test programs

`programs/*.dsl` — 12 representative programs (8 Tier-1 + 4 3D/mixer), each with a fixed
`seed: 1` so output is deterministic:

| file | effect | shape |
|---|---|---|
| `solid.dsl`     | `synth/solid`    | single-pass color fill |
| `noise.dsl`     | `synth/noise`    | single-pass value/simplex noise |
| `cell.dsl`      | `synth/cell`     | single-pass cellular/Voronoi |
| `gradient.dsl`  | `synth/gradient` | single-pass gradient |
| `shape.dsl`     | `synth/shape`    | single-pass SDF shape |
| `osc2d.dsl`     | `synth/osc2d`    | single-pass oscillator |
| `blur.dsl`      | `filter/blur`    | multi-pass H/V separable blur over noise |
| `blendMode.dsl` | `mixer/blendMode`| two-surface blend (o0 → o1) |
| `palette3d.dsl` | `filter3d/palette3d` | recolor a 3D volume by palette, viewed via render3d |
| `mashup.dsl` | `mixer/mashup` | luminance-band router (incl. active-when-wired fallback) |
| `renderCubemap3d.dsl` | `render/renderCubemap3d` | lit cubemap-face volume render (single face) |
| `renderCubemapSurface.dsl` | `render/renderCubemapSurface` | raw emission/absorption cubemap face |

## Runbook

```bash
# 0. (once / when JS definitions change) regenerate ALL Unity effect-definition
#    JSON from the reference definitions. Supersedes the hand-written Tier-1 JSON.
node tools/convert-definitions.mjs            # writes unity/.../Effects/<ns>/<func>.json

# 1. Export golden PNG + normalized graph.json for one program.
#    Fixed: 256x256, normalized time 0.25, seed baked into the DSL.
node parity/export-and-render.mjs parity/programs/noise.dsl parity/out \
     --size 256 --time 0.25 --backend webgl2
#    -> parity/out/noise.golden.png  and  parity/out/noise.graph.json

# 2. Render the Unity candidate from the SAME graph.json (batchmode).
"$UNITY" -batchmode -quit -projectPath "$UNITY_PROJECT" \
  -executeMethod Noisemaker.Hlsl.Editor.NMParityRunner.RenderFromCommandLine \
  -nmGraph "$PWD/parity/out/noise.graph.json" \
  -nmOut   "$PWD/parity/out/noise.candidate.png" \
  -nmSize 256 -nmTime 0.25
#    (Editor menu equivalent: Noisemaker ▸ Parity ▸ Render Graph To PNG…)

# 3. Diff. Per-program tolerance; loosen --tolerance for stochastic/feedback effects.
python parity/compare.py \
  parity/out/noise.golden.png parity/out/noise.candidate.png \
  --name synth/noise --tolerance 2 --ssim-min 0.98 \
  --report parity/out/noise.report.json
#    exit 0 = within tolerance, 1 = divergence.
```

Loop over all programs with a shell `for` over `parity/programs/*.dsl`.

## Graph parity (live-DSL compiler)

The pixel harness above validates the *shaders + executor* from a precompiled graph. A
second, **GPU-free** harness validates the **C# live DSL compiler** (`Compiler/`) by
diffing the graph it produces against the reference `export-graph.mjs` oracle, byte-for-byte:

```
  DSL ─┬─ tools/export-graph.mjs ─────────────────────► <name>.ref.graph.json ─┐
       └─ NMParityRunner.CompileDslDumpBatchFromCommandLine (Unity, 1 session)  ├─► graph-diff.py ─► PASS/FAIL
                                                          <name>.cs.graph.json ─┘
```

Run it (one Unity session for all programs; no rendering):

```bash
UNITY=/path/to/Unity UNITY_PROJECT=/path/to/proj ./parity/graph-verify.sh         # all programs
UNITY=... UNITY_PROJECT=... ./parity/graph-verify.sh noise mashup                 # a subset
```

`graph-diff.py` compares the normalized graphs structurally, ignoring the per-instance
`id` hash and `source`; a clean run is `0 deltas`. **Current status: 12/12 programs
byte-clean** — the C# normalized graph is identical to the reference oracle. This is the
"diffed against the golden path" validation the live-DSL path was always meant to have.

## Parity hazards (must match between golden and candidate)

- **Color space** — RTs are `ARGBHalf` + `RenderTextureReadWrite.Linear`; **never
  sRGB**. Both renderers quantise the linear float readback `round(v*255)` with no
  gamma. Unity project must be Linear.
- **Y orientation** — the JS golden flips GL bottom-left origin to top-down PNG
  rows; Unity's `ReadPixels` is already top-down. The single reconciliation point
  is `NMBlit` / the runner. `// TODO(verify)` against `gradient.dsl` (a directional
  pattern) once both PNGs exist; mirror in the runner if a vertical flip appears.
- **Premultiplied alpha** — the WebGPU reference present path is premultiplied
  (`reference/04 §7`); match it if rendering the golden with `--backend webgpu`.
- **Determinism** — seed is in the DSL; time is pinned (paused). Both sides render
  8 frames at the pinned normalized time so feedback/state surfaces settle.

## Files

- `export-and-render.mjs` — golden renderer (graph.json + golden.png).
- `compare.py` — max-abs-diff + global SSIM gate, JSON report (pixel parity).
- `graph-verify.sh` — graph-parity harness (all programs: C# live graph vs the oracle).
- `graph-diff.py` — structural graph diff (ignores the `id` hash + `source`).
- `programs/*.dsl` — fixed-seed test programs (pixel + graph parity).
- `../unity/com.noisemaker.hlsl/Editor/NMParityRunner.cs` — Unity candidate renderer + `CompileDslDumpBatchFromCommandLine` (graph dumper).
- `../tools/export-graph.mjs` — golden graph producer (used by both harnesses).
- `../tools/convert-definitions.mjs` — effect-definition regenerator (step 0).
