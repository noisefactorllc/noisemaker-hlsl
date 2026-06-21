# Quick Start sample

A minimal end-to-end example: render a bundled Noisemaker graph to a `RenderTexture` and
display it on a material.

## Contents

- `NMQuickStartExample.cs` — a small MonoBehaviour that drives an `NMRenderer` from a
  `GraphJson` TextAsset and assigns the output to a `Renderer`'s material.
- `NoiseGraph.json` — a precompiled graph (`noise → blur`) exported with the repo's
  `tools/export-graph.mjs`; the recommended/verified input path.

## Run it

1. **Project Settings ▸ Player ▸ Color Space = Linear.** Required — a Gamma project renders
   incorrect colors with no warning.
2. Create a quad: *GameObject ▸ 3D Object ▸ Quad*. Give it an **Unlit/Texture** material.
3. Add the **Quick Start Example** component (*Add Component ▸ Noisemaker ▸ Samples*) to any
   GameObject. Assign:
   - **Graph Json** → `NoiseGraph.json` (imported alongside this script).
   - **Target** → the Quad's `MeshRenderer`.
4. Press **Play**. The quad shows animated noise.

## Notes

- **Builds:** the package's `NMShaderInclusionBuildStep` automatically includes the
  `Noisemaker/*` shaders in player builds, so this works in a build with no extra setup.
- **Your own content:** export any DSL program with `tools/export-graph.mjs`, import the
  resulting `.json` as a TextAsset, and assign it to **Graph Json**. To compile DSL at
  runtime instead, set `NMRenderer.Dsl` and assign `EffectDefinitions` (the package's
  `Effects/**/*.json` TextAssets) — note the live compiler is early/unverified; prefer
  `GraphJson` for anything you ship.
- See the package README for the full Host API, performance, lifecycle, and troubleshooting
  guidance.
