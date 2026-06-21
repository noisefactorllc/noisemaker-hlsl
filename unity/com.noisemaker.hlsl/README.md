# Noisemaker HLSL (com.noisemaker.hlsl)

Live procedural textures from the Noisemaker Polymorphic DSL, rendered in Unity via
HLSL — pixel-identical to the JS/WebGPU reference engine. Use it as a standalone
renderer that writes a `RenderTexture`, or drop single-pass effects into Shader Graph
as Custom Function nodes.

> **🚧 WIP — very early development.** Not recommended for general use until it has been
> fully tested, performance has been addressed, and integration is proven beyond the
> Built-in pipeline. Treat all current output as provisional. **Read "Requirements" and
> "Builds & platforms" below before integrating — the defaults will not "just work."**

> This README is for **integrators** (using the package). Contributors porting shaders
> should read `../../PORTING-GUIDE.md`, `../../ARCHITECTURE.md`, and `../../parity/` —
> none of which you need to *use* the package.

## Requirements

- **Unity 6 (verified on `6000.3.16f1`).** The manifest min is `2021.3`, but the package
  is only verified on Unity 6; older versions are untested.
- **Linear color space — mandatory.** Set *Project Settings ▸ Player ▸ Color Space =
  Linear*. All render targets are `ARGBHalf`, non-sRGB. In a **Gamma** project (the
  Built-in/2D template default) every color is silently wrong (washed-out/dark); the
  runtime does not warn.
- **GPU: Shader Model 4.5+** (`#pragma target 4.5`). This excludes OpenGL ES 2/3.0,
  pre-DX11, and **WebGL**, and requires half/float render-target support.
- **Render pipeline:** **verified on Built-in only.** The engine is pipeline-agnostic by
  design (it submits a `CommandBuffer` via `Graphics.ExecuteCommandBuffer` and uses no
  SRP-specific hooks), so URP/HDRP are *expected* to work but are **not yet verified**.
  It renders to its own offscreen `RenderTexture`; it is **not** an SRP camera/feature,
  and presenting that texture full-screen is your responsibility (and differs per pipeline).
- **Shader Graph** (`com.unity.shadergraph`) is required only for integration path 2
  (Custom Function nodes). It is intentionally *not* a hard `package.json` dependency, so
  path-1 (renderer) users don't have to install it.

## Installation

Add the package by either route (the package lives in a subfolder, not the repo root):

- **From disk:** *Package Manager ▸ Add package from disk…* →
  `…/noisemaker-hlsl/unity/com.noisemaker.hlsl/package.json`.
- **From git:** *Add package from git URL…* →
  `https://github.com/noisefactorllc/noisemaker-hlsl.git?path=unity/com.noisemaker.hlsl#<tag>`.

### Builds & platforms

The runtime resolves each effect shader by name via `Shader.Find("Noisemaker/<ns>/<func>")`,
and Unity strips shaders that no scene/material references. The package ships an automatic
Editor build step (`NMShaderInclusionBuildStep`) that adds every `Noisemaker/*` shader to
*Always Included Shaders* for the duration of a player build and restores your list
afterward — so **builds resolve the shaders with no setup**. (To manage it yourself instead,
run *Noisemaker ▸ Builds ▸ Add shaders to Always Included* once, or ship the shaders in a
`Resources/` folder. The auto step is skipped only if you strip the Editor assembly.)

Also note for builds:
- **Build-safe** source paths: `GraphJson` (TextAsset) and `EffectDefinitions` (TextAsset[]).
  **Editor-only:** `EffectsDirectory` and `LoadMeshFromFile` use `System.IO`.
- Mesh effects need OBJ data supplied as `TextAsset`s via `LoadMesh(...)`; no meshes are
  bundled, so mesh/3D-geometry effects render nothing until you provide them.
- IL2CPP/AOT has not been validated.

## Getting started (standalone renderer → RenderTexture)

> A ready-to-run **Quick Start** sample (a bundled graph + an example script that renders to
> a material) is importable from the Package Manager *Samples* tab.

The most reliable input is a **precompiled graph** (`GraphJson`) — it needs no effect
registry and is the path verified by the parity harness. Export one with the repo's
`tools/export-graph.mjs`, import the resulting `.json` as a `TextAsset`, and:

```csharp
using Noisemaker.Hlsl;

var r = gameObject.AddComponent<NMRenderer>();
r.GraphJson = myGraphJsonTextAsset;   // graph.json from tools/export-graph.mjs, imported as a TextAsset
r.RenderWidth = 512; r.RenderHeight = 512;
r.Rebuild();                          // (re)build the pipeline after assigning a source

// Output is produced once per LateUpdate while Animate == true (the default).
// It is null until the first frame, so read it from your own LateUpdate/Update —
// re-read each time; do NOT cache it across Resize()/disable.
someMaterial.mainTexture = r.Output;  // an ARGBHalf (linear) RenderTexture
```

For a single deterministic frame (no animation), drive time yourself:

```csharp
r.Animate = false;
r.Rebuild();
r.RenderFrame(0f);                    // render normalized time 0..1
someMaterial.mainTexture = r.Output;  // valid immediately after RenderFrame
```

### Live DSL (early / unverified)

You can instead compile a DSL string at runtime — but the live C# compiler is **not yet
validated against the golden export**, and it needs the effect definitions:

```csharp
var r = gameObject.AddComponent<NMRenderer>();
r.Dsl = "search synth\nnoise(scaleX: 60).write(o0)\nrender(o0)";
r.EffectDefinitions = myEffectJsonTextAssets;  // the package's Effects/**/*.json, imported as TextAssets
r.Rebuild();                                   // Dsl is a plain field — assign, then Rebuild()
r.RenderFrame(0f);
someMaterial.mainTexture = r.Output;
```

Without `EffectDefinitions` (or `EffectsDirectory`, Editor-only) the live path logs
"Live DSL needs effect definitions…" and renders nothing. Prefer `GraphJson` for anything
you ship. `GraphJson` takes precedence over `Dsl` when both are set.

> The package has **no texture/camera/video input** — it is output-only. The `media`
> effect is a definition-only stub with no shader and will fail to render.

## Host API (`NMRenderer`)

| Member | Purpose |
|---|---|
| `TextAsset GraphJson` | Precompiled graph source (recommended; precedence over `Dsl`). |
| `string Dsl` | DSL source compiled at runtime (early/unverified; needs `EffectDefinitions`). |
| `TextAsset[] EffectDefinitions` | Effect JSONs for the live DSL path (build-safe). |
| `string EffectsDirectory` | Filesystem dir of effect JSONs (Editor/dev only). |
| `int RenderWidth/Height` | Render resolution (default 800×600). |
| `bool Animate` / `float AnimationDuration` | Auto-advance normalized time each `LateUpdate` (`(Time.time/duration)%1`); default on, 10s. |
| `RenderTexture Output` | Current output (null before the first frame / after disable; recreated on `Resize`/`Rebuild`). |
| `void Rebuild()` | Re-obtain the graph + rebuild the pipeline after changing a source field. |
| `void RenderFrame(float t)` | Render one explicit normalized-time frame; sets `Output`. |
| `void Resize(int,int)` | Change resolution (recreates surfaces + `Output`). |
| `void SetUniform(string,object)` | Set a global uniform — **numeric only** (float/int/bool); other types are ignored. |
| `int LoadMesh(string,TextAsset)` | Upload an OBJ TextAsset into a mesh surface (build-safe). |

The lower-level `NMPipeline` (via `r.Pipeline`) additionally exposes `GetOutput(surfaceName)`,
`PresentTo(RenderTexture)`, and `RenderCubemap(faceSize, surface, time)` → a `TextureCube`
(the caller must `Release()` the returned RT; note its per-face `flipU/flipV` D3D-orientation
defaults).

## Shader Graph Custom Function nodes (single-pass effects)

Most single-pass generators/filters ship a wrapper in `ShaderGraph/CustomFunctions/<Effect>.hlsl`
exposing e.g. `void NM_Noise_float(float2 UV, float2 Resolution, /*params*/, out float4 Out)`.
Add a **Custom Function** node (File mode), point it at the include, and set the function
**name without the precision suffix** (`NM_Noise`, not `NM_Noise_float`) — Shader Graph picks
`_float`/`_half` itself; including the suffix silently fails to bind. Wire the named inputs.

Not every effect has a node: multi-pass, agent, 3D, and a few single-pass effects
(`mashup`, `remap`, `media`) are runtime-only — use the renderer path for those.

## Performance & cost

Performance has not been optimized; some effects are very expensive. Cost knobs:

- **`RenderWidth/Height`** — the dominant cost for raymarch/fluid/feedback effects. Start
  low (e.g. 256²) and scale up.
- **Particle/agent effects** (`points*`, `flow`) scale with `stateSize²` (capped at 2048 ⇒
  up to ~4.2M agents). Keep `stateSize` modest.
- **3D effects** raymarch a 64×4096 volume atlas; **`RenderCubemap` re-renders the entire
  graph 6×** per call.
- With `Animate = true` the graph renders **every `LateUpdate`** (an always-on GPU cost);
  set `Animate = false` and call `RenderFrame` on demand for static output.

## Lifecycle & memory

- `Output` is a live internal `RenderTexture`, recreated on `Resize()`/`Rebuild()` and set
  to null on disable — **re-fetch it; never cache across a resize/disable**. To keep a frame,
  `Graphics.Blit` it into your own RT.
- Resources are disposed on `OnDisable`. The `RenderTexture` returned by
  `NMPipeline.RenderCubemap` is owned by the caller — `Release()` it.
- All API is main-thread. VRAM grows with resolution, surface count, and `stateSize`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Black output + "Shader not found" log | Package shaders stripped from the build | Add `Noisemaker/*` to Always Included Shaders / `Resources/` (see Builds). |
| Nothing renders, no error | No source assigned, or `Output` read before the first frame | Assign `GraphJson`/`Dsl`, call `Rebuild()`, read `Output` after `LateUpdate`/`RenderFrame`. |
| Log: "Live DSL needs effect definitions…" | `Dsl` set without `EffectDefinitions` | Assign `EffectDefinitions` (the `Effects/**/*.json` TextAssets) or use `GraphJson`. |
| Washed-out / dark / wrong colors | Project is Gamma color space | Switch to Linear (see Requirements). |
| Custom Function node binds to nothing | Function name includes `_float`/`_half` | Use the base name (`NM_Noise`). |
| Mesh/3D-geometry effect renders nothing | No OBJ supplied | `LoadMesh(name, objTextAsset)`. |

## How it works

DSL → **Render Graph** → `NMPipeline` executes the graph by Blitting fullscreen passes
into linear `ARGBHalf` RenderTextures (double-buffered user surfaces `o0..o7`, pooled
intermediates), then presents the render surface. The graph comes from a precompiled
`graph.json` (via the repo's `tools/export-graph.mjs`, guaranteeing parity with the
reference) or from the live C# compiler (`Noisemaker.Hlsl.Compiler.DslCompiler`). See
`../../ARCHITECTURE.md`.

## Assembly definitions

- `Noisemaker.Hlsl.Compiler` — pure C#, no UnityEngine (lexer/parser/expander + graph model).
- `Noisemaker.Hlsl.Runtime` — the executor + `NMRenderer` (references Compiler). Reference this.
- `Noisemaker.Hlsl.Editor` — parity runner + import tooling (Editor only; do not reference from runtime/build code).

## License

MIT — see [`LICENSE.md`](LICENSE.md). Use of the Noisemaker / Noise Factor names is subject
to the repo's Trademark Policy.
