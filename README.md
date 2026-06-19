# noisemaker-hlsl

A parallel port of the [Noisemaker shader engine](../shaders) to **Unity / HLSL**.
It renders **live procedural textures from the Polymorphic DSL**, aiming to be
**pixel-identical** to the JS/WebGPU reference engine, and exposes effects both as a
standalone renderer and as **Shader Graph (material) nodes**.

> ProgramState and UI bindings from the reference are intentionally out of scope.
> The reference engine in `../shaders` is the ground truth; this tree never modifies it.

## Layout

```
noisemaker-hlsl/
├─ README.md                 ← you are here
├─ ARCHITECTURE.md           ← system design; how each reference subsystem maps to C#/HLSL
├─ PORTING-GUIDE.md          ← the GLSL/WGSL → HLSL rulebook (read before porting a shader)
├─ docs/GRAPH-JSON-SCHEMA.md ← the Render Graph JSON contract (exporter ↔ C# runtime)
├─ reference/                ← precise re-implementer specs of every reference subsystem (01–10)
├─ unity/com.noisemaker.hlsl/← the Unity package (UPM, drop-in)
│  ├─ Runtime/   ← RenderGraph executor (CommandBuffer Blit pipeline; pipeline-agnostic)
│  ├─ Compiler/  ← C# DSL frontend (lex→parse→validate→expand) + shared graph model
│  ├─ Shaders/   ← NMCore/NMFullscreen includes + per-effect HLSL ports + NMBlit
│  ├─ ShaderGraph/← per-effect Custom Function node wrappers
│  ├─ Effects/   ← effect definition JSON consumed by the runtime
│  └─ Editor/    ← parity runner + tooling
├─ tools/                    ← Node: export-graph (golden), convert-definitions (regenerate Effects/*.json)
└─ parity/                   ← golden-image harness + comparison + test programs
```

## The core idea: a shared Render Graph

The reference compiles DSL into a **Render Graph** (`passes / programs / textures /
renderSurface`). That is the seam. noisemaker-hlsl produces the same graph two ways:

- **Golden / offline** — `tools/export-graph.mjs` runs the *unchanged reference*
  `compileGraph` and serialises the graph to JSON (zero graph-construction parity risk).
- **Live / in-Unity** — the C# `Compiler/` port compiles DSL at runtime, validated by
  diffing its graph JSON against the golden path.

Both feed the same `NMPipeline` executor + HLSL shaders, so visual parity depends only
on the shaders and the executor — see [ARCHITECTURE.md](ARCHITECTURE.md).

## Quick start (once opened in Unity)

1. Add the package: in a Unity project, *Package Manager → Add package from disk →*
   `noisemaker-hlsl/unity/com.noisemaker.hlsl/package.json`.
2. Add an `NMRenderer` component, set its DSL (e.g. `search synth\nnoise().write(o0)\nrender(o0)`).
3. Read `NMRenderer.Output` (an `ARGBHalf` `RenderTexture`) into any material, or
   drop a Noisemaker **Custom Function node** into a Shader Graph.

## Status

**Compiles and renders in Unity 6** (verified on 6000.3.16f1). The C# engine compiles
clean and all 180 shaders compile; driving `NMParityRunner` in batchmode produced correct
output for `solid` (exact `#FF8000` fill), `noise` (multi-octave RGB simplex), and a
multi-pass `noise → blur` chain (correctly softened — exercises pooled intermediates +
filter input sampling + per-pass selection). Parity-critical shaders (PCG, noise, cell,
blend, blur) were additionally hardened by adversarial line-by-line review vs the WGSL.

**Pixel parity verified** via the `parity/` harness (JS/WebGL2 golden in headless Chromium
↔ Unity candidate ↔ `compare.py`). All **8/8 Tier-1 test programs are pixel-identical**
(within 1/255 = float→8-bit rounding, SSIM 1.00000): `solid`, `noise`, `cell`, `gradient`,
`shape`, `osc2d`, the multi-pass `blur`, and the two-surface mixer `blendMode`.

The Y-flip reconciliation the design anticipated is now solved properly: Unity flips Y once
per `DrawProcedural` into a RenderTexture, so textures of odd-vs-even render depth ended up
oppositely oriented (only exposed when a mixer samples two such inputs — `blendMode`).
`NMVertFullscreen` counter-flips clip-space Y by `_ProjectionParams.x`, making every pass
store one consistent orientation regardless of depth. sRGB/linear and FMA are confirmed
correct by the SSIM-1.0 matches.

Bringing up Unity + the parity harness surfaced (and fixed) real bugs static review missed:
C# variable shadowing, a `PassType` namespace clash, an `NMBlit` include path + `src` input
name, batchmode `Shader.Find` resolution, multi-pass `Material.FindPass` selection, ShaderLab
reserved-word collisions in the (now-removed, MPB-driven) `Properties` blocks, the HLSL
reserved word `point` in `Cell.hlsl`, and `export-graph` starter-op + compile-time-`define`
promotion. See `parity/README.md` for the runbook.

**Effect coverage: 179 / 180** — every namespace complete:
`synth` 28/29 · `filter` 90/90 · `mixer` 14/14 · `classicNoisedeck` 20/20 · `points` 10/10 ·
`synth3d` 7/7 · `filter3d` 1/1 · `render` 9/9. (Only `synth/media`, an external image/video
input, is out of scope — it belongs to the skipped external-input/UI layer.)

Each ported effect ships an `.hlsl` core, a `.shader`, and a runtime `Effects/*.json`;
single-pass effects also ship a Shader Graph Custom Function node. Every port is faithful to
the reference **WGSL**; PRNG-heavy, multi-pass, agent, and 3D ports were additionally
hardened by adversarial line-by-line review against the WGSL.

The runtime was hardened in stages to execute the harder patterns: **feedback/state**
(persistent surfaces, `repeat:` ping-pong, MRT), **agents** (`DrawProcedural(Points)`
scatter + additive deposit + `rgba32f` state), and **3D/mesh** (64×4096 volume atlas +
raymarch, OBJ loader + mesh-data textures, loop expansion). The C# DSL frontend handles
multi-statement programs, `read(oN)` / mid-chain `.write()`, `let` bindings, multi-input
(mixer) chains, and `loopBegin`/`loopEnd`; `subchain`/`if`/`write3d` remain staged.

`tools/convert-definitions.mjs` regenerates all effect-definition JSONs automatically; the
per-effect port path is documented in [PORTING-GUIDE.md](PORTING-GUIDE.md).
