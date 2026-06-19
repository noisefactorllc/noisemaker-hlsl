# noisemaker-hlsl — Architecture

A parallel port of the Noisemaker shader engine (`../shaders`) to Unity / HLSL.
Goal: **live procedural texture from the Polymorphic DSL, pixel-identical to the
JS reference engine.** ProgramState and UI bindings are out of scope. The package
is a drop-in UPM module usable both as a standalone renderer and as Shader Graph
(material-node) building blocks.

## The seam: the Render Graph

The JS engine compiles DSL in stages: `lex → parse → validate → expand →
allocateResources → Pipeline`. The clean architectural seam is the **Render Graph**
— the `graph` object produced by `compileGraph(dsl)` (`reference/03`, `reference/04`):

```
graph = { passes[], programs{}, textures(Map), renderSurface, ... }
```

Everything downstream of the graph (texture pooling, double-buffering, pass
execution, presentation) is backend work. Everything upstream is pure data logic.
noisemaker-hlsl mirrors this split and gives the graph **two producers**:

```
                          ┌─────────────────────────────────────────┐
   DSL source ──►         │  Render Graph (passes/programs/textures)  │  ──► NMPipeline (Unity)
                          └─────────────────────────────────────────┘
        ▲                                   ▲
        │ (a) GOLDEN / OFFLINE              │ (b) LIVE / IN-UNITY
        │  tools/ runs the *real* JS        │  C# DSL frontend port
        │  compileGraph → graph.json        │  (Compiler/ asmdef)
        │  (zero parity risk)               │  validated against (a)
```

- **(a) Golden path** — `tools/export-graph.mjs` runs the *unchanged reference*
  `compileGraph` and serialises the graph to JSON. Used for presets and as the
  ground truth for the live path. Carries zero graph-construction parity risk
  because it is literally the reference code.
- **(b) Live path** — `Compiler/` ports the DSL frontend to C# so Unity can compile
  DSL at runtime. It is validated by diffing its graph JSON against (a). Where the
  live port is incomplete, the runtime can still load golden graph JSON directly.

Both paths feed the same `RenderGraph` C# model and the same `NMPipeline` executor,
so visual parity depends only on the executor + shaders, not on which producer ran.

## Runtime (`Runtime/` asmdef) — `Noisemaker.Hlsl.Runtime`

A CommandBuffer-based executor. **All reference effects are render-pass based**
(`reference/10`: no `type:compute` in any definition; agents/GPGPU use MRT +
points-scatter + repeat loops), so we mirror the **WebGL2 GPGPU model** rather than
Unity compute shaders. This keeps the engine render-pipeline-agnostic (Built-in,
URP, HDRP — it only needs `CommandBuffer.Blit`/`DrawProcedural`).

| Reference | noisemaker-hlsl |
|---|---|
| `resources.js` liveness + linear-scan pool | `Graph/TexturePool.cs` — ported 1:1 (deterministic, insertion-ordered). `phys_N` numbering matches. |
| `pipeline.js` surfaces (`o0..o7`, geo, vol, mesh) | `Pipeline/SurfaceManager.cs` — double-buffered `RenderTexture` pairs, ARGBHalf linear. |
| 3-tier double-buffer (§10.2/10.6/10.7) + `isStateSurface` | `Pipeline/SurfaceManager.cs` — exact swap/persist predicate. |
| `backend.executePass` (render/MRT/points/repeat/blend) | `Backend/NMRenderBackend.cs` — `CommandBuffer` Blit / `DrawProcedural` / MRT `SetRenderTarget`. |
| fullscreen triangle VS + default present blit | `Shaders/Include/NMFullscreen.hlsl`, `Shaders/NMBlit.shader`. |
| per-frame uniform flow | `Pipeline/UniformBinder.cs` → `MaterialPropertyBlock` (named uniforms; see PORTING-GUIDE). |
| `Pipeline.render(time)` control flow | `Pipeline/NMPipeline.cs` — frame loop, skip/repeat/present, normalized 0..1 time. |
| host API (`getOutput`, `setUniform`, resize) | `Driver/NMRenderer.cs` (MonoBehaviour) + `NMRenderTexture` output. |

Out of scope for the first cut (marked TODO in code): MIDI/audio automation,
oscillator automation binding, tiled hi-res export, async/CPU texture init
(worm tracing), 3D volumes & mesh rendering. The graph model carries the fields so
they can be added without reshaping.

## Compiler (`Compiler/` asmdef) — `Noisemaker.Hlsl.Compiler`

C# port of the DSL frontend (`reference/01,02,03`): `Lexer`, `Parser`, `Ast`,
`Validator`, `Expander`, `Resources`, plus the enum/alias registries. First cut
targets linear generator→filter→`write`/`render` chains over the ported effects;
`subchain`, `if/elif`, loops, 3D, and agents are staged. Parity-critical details
captured from the specs: constant folding in IEEE `double`, palette index =
positional key order, global `tempIndex` allocation order, first-match namespace
resolution. The C# graph output is diffable against the golden path.

## Shaders (`Shaders/`)

- `Include/NMCore.hlsl` — bit-exact shared primitives (PCG/prng/random/`nm_mod`/
  `nm_positiveModulo`/`map`/`periodicFunction`). Nothing per-effect-variable.
- `Include/NMFullscreen.hlsl` — fullscreen-triangle VS, engine uniforms, coord
  helpers, reference-name `#define` aliases.
- `Effects/<ns>/<Effect>.{hlsl,shader}` — per-effect ports (see PORTING-GUIDE).
- `NMBlit.shader` — the present/copy blit (the single Y-flip reconciliation point).

## Shader Graph integration (`ShaderGraph/`)

Two integration levels:
1. **Per-effect Custom Function nodes** — `ShaderGraph/CustomFunctions/<Effect>.hlsl`
   exposing `void NM_<Effect>_float(...inputs, out float4 Out)`. Single-pass
   generators (noise, cell, solid, shape, gradient…) drop straight into Shader
   Graph as nodes with named inputs. This is the "material node system" compatibility.
2. **Runtime RenderTexture** — multi-pass effects (blur, agents, fluid) are rendered
   by `NMRenderer` into an `ARGBHalf` RenderTexture which any material/Shader Graph
   samples as a `Texture2D`. Documented in the package README.

## Validation (`parity/`)

- `parity/export-and-render.mjs` — for each test DSL program, renders the reference
  GPU output to PNG via the vendored `shade-mcp` Playwright harness (golden), and
  exports the graph JSON.
- `Editor/NMParityRunner.cs` — Unity batchmode: load the same DSL/graph, render to an
  ARGBHalf RenderTexture, read back to PNG.
- `parity/compare.py` — max-abs-diff + SSIM with per-effect tolerance (mirrors the
  repo's existing `scripts/image_regression.py` conventions).

See `reference/` for the full re-implementer specs of every reference subsystem.
**Status:** built correct-by-construction; not yet compiled/rendered (no Unity/Node
in the authoring session). The parity harness is how each piece gets verified.
