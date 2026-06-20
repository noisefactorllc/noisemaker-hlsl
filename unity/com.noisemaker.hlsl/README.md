# Noisemaker HLSL (com.noisemaker.hlsl)

Live procedural textures from the Noisemaker Polymorphic DSL, rendered in Unity via
HLSL. Pixel-identical to the JS/WebGPU reference engine. Usable as a standalone
renderer or as Shader Graph building blocks.

> **🚧 WIP — very early development.** This project is in **very early development and is
> not recommended for general use** until it has been fully tested, performance has been
> addressed, and detailed integration guidance is provided. Treat all current output as
> provisional.

Compatible with the **Built-in**, **URP**, and **HDRP** render pipelines — the engine
only uses `CommandBuffer` Blits and `DrawProcedural`, no pipeline-specific hooks.

## Two ways to use an effect

### 1. Standalone renderer → RenderTexture

```csharp
var r = gameObject.AddComponent<NMRenderer>();
r.Dsl = "search synth\nnoise(scaleX: 60).write(o0)\nrender(o0)";
// r.Output is an ARGBHalf (linear) RenderTexture, updated every frame.
someMaterial.mainTexture = r.Output;
```

This is the path for multi-pass effects (blur, fluid, agents) and full DSL chains.

### 2. Shader Graph Custom Function node (single-pass generators/filters)

Each single-pass effect ships a wrapper in `ShaderGraph/CustomFunctions/<Effect>.hlsl`
exposing e.g. `void NM_Noise_float(float2 UV, float2 Resolution, /*params*/, out float4 Out)`.
Add a **Custom Function** node (File mode), point it at the include, set the function
name, and wire the named parameter inputs. The node computes the effect inline in your
material — this is the "material node system" integration.

## How it works

DSL → **Render Graph** → `NMPipeline` executes the graph by Blitting fullscreen passes
into linear `ARGBHalf` RenderTextures (double-buffered surfaces `o0..o7`, pooled
intermediates), then presents `renderSurface`. The graph comes either from the live C#
compiler (`Noisemaker.Hlsl.Compiler.DslCompiler`) or from a precompiled `graph.json`
(produced by the repo's `tools/export-graph.mjs`, guaranteeing graph parity with the
reference). See `../../ARCHITECTURE.md`.

## Parity notes (important)

- Render targets are **linear, non-sRGB** half-float. Don't enable sRGB on the output RT.
- Shaders are ported from the reference **WGSL** (top-left origin, matching D3D). If a
  given graphics API mirrors vertically, flip once via `#define NM_FLIP_Y 1` in `NMCore.hlsl`.
- Verify any new port with the repo's `parity/` harness before trusting it.

## Assembly definitions

- `Noisemaker.Hlsl.Compiler` — pure C#, no UnityEngine (lexer/parser/expander + graph model).
- `Noisemaker.Hlsl.Runtime` — the executor + `NMRenderer` (references Compiler).
- `Noisemaker.Hlsl.Editor` — parity runner + import tooling (Editor only).
