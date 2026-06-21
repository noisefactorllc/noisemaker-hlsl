# Changelog

All notable changes to this package are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this package aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The package is in early
development (pre-1.0); APIs may change.

## [Unreleased]

### Added
- 3D cubemap renderers `render/renderCubemap3d` and `render/renderCubemapSurface`, plus an
  `NMPipeline.RenderCubemap(faceSize, surface, time)` → Unity `TextureCube` driver
  (`NMCubeCamera` 6-face basis; per-face GL→D3D orientation reconciliation).
- `filter3d/palette3d` — cosine-palette recolor of a 3D volume (per-voxel, geometry passthrough).
- `mixer/mashup` — luminance-band router (posterize a control input into N bands, route each
  band to a wired surface; unwired bands fall back to the control).
- `mat3` (`float3x3`) uniform binding in `UniformBinder` (drives `cubeBasis`).
- Integrator documentation: **Requirements**, **Builds & platforms**, **Host API**,
  **Troubleshooting**, **Performance & cost**, and **Lifecycle & memory** sections in the
  package README; `docs/INTEGRATION-DOCS-REVIEW.md`.
- Build step (`NMShaderInclusionBuildStep`, Editor-only) that auto-adds the `Noisemaker/*`
  shaders to *Always Included Shaders* during a player build and restores the list
  afterward — so the runtime resolves shaders in players with no manual setup. Also a
  *Noisemaker ▸ Builds ▸ Add shaders to Always Included* menu item.
- In-package `LICENSE.md`.

### Changed
- Renamed `render/renderCubemap3D` → `renderCubemap3d` (lowercase `3d` for func/program/shader;
  display name stays `RenderCubemap3D`).
- Documentation accuracy pass: corrected effect counts/tallies, parity-program count, stale
  capability claims, and the render-pipeline support statement (verified on Built-in; URP/HDRP
  unverified). Scoped "validated" claims to the precompiled `GraphJson` path; the live DSL
  compiler is still early/unverified.

## [0.1.0]

Initial UPM package.

### Added
- DSL → Render Graph → `NMPipeline` runtime renderer (`NMRenderer` MonoBehaviour) and Shader
  Graph Custom Function nodes for single-pass effects.
- 184 effect definitions across 8 namespaces (`synth`, `filter`, `mixer`, `classicNoisedeck`,
  `points`, `synth3d`, `filter3d`, `render`); Tier-1 programs pixel-identical to the JS/WebGPU
  reference.
- `parity/` golden-image verification harness.
