# Integration-docs review — `com.noisemaker.hlsl`

_Audit date: 2026-06-20. Method: a five-dimension docs↔code audit (install · public API · constraints · accuracy/drift · completeness) producing 49 findings, each adversarially verified against the source, cross-checked against Unity UPM / render-pipeline package ecosystem norms. Effect/shader/parity counts verified against the `Effects/` and `Shaders/` trees on the audit date._

This document is the checklist for making the package's **developer integration guidance** complete and accurate. It targets a developer dropping this package into their own Unity project — not contributors (see `PORTING-GUIDE.md`, `parity/`, `reference/` for that).

## Verdict

**Not yet complete or accurate enough for an external integrator to rely on** — consistent with the package's own "very early development / not recommended for general use" banner. Two issues dominate:

1. **The headline Quick Start does not run** — the live-DSL path needs `EffectDefinitions`, which the sample never assigns (and the component's lifecycle means `Output` is null at the moment the sample reads it).
2. **Nothing renders in a player build** — every pass resolves via `Shader.Find`, and the package registers no shaders for builds (no `Resources/`, no Always-Included list); the working resolver is Editor-only.

Both failures are documented only in source comments. Beyond them, the docs omit the hard **Linear color-space** requirement, lack input/performance/lifecycle/troubleshooting guidance, and carry several stale capability and effect-count claims. The engine compiles and renders correctly in-Editor on the one verified setup — **the gap is in the docs, not the engine.**

## Must-fix (blockers + critical)

1. **Player builds render nothing — shader stripping.** Passes resolve via `Shader.Find("Noisemaker/<ns>/<func>")` (`Runtime/Backend/NMShaderRegistry.cs:72`); Unity strips package shaders not in `Resources/` or *Always Included Shaders*. The only `ExternalResolver` wiring is Editor-only (`Editor/NMParityRunner.cs:656`). Builds produce black + "Shader not found" (`Runtime/Pipeline/NMPipeline.cs:119-123`). **Fix:** a "Builds" section requiring `Noisemaker/*` shaders in *Project Settings ▸ Graphics ▸ Always Included Shaders* (or shipped in `Resources/` / a `ShaderVariantCollection`); ideally ship an `IPreprocessBuildWithReport` auto-registrar.
2. **Headline Quick Start doesn't run — missing `EffectDefinitions`.** The sample (`unity/com.noisemaker.hlsl/README.md:19-24`) sets `r.Dsl` then reads `r.Output`; the live path returns null and logs "Live DSL needs effect definitions…" (`NMRenderer.cs:108-115`) unless `EffectDefinitions`/`EffectsDirectory` is set — never mentioned. **Fix:** show assigning `EffectDefinitions` (the package's `Effects/**/*.json` TextAssets) or use the registry-free `GraphJson` path.
3. **Quick Start lifecycle bug — `Output` null when read.** `AddComponent` runs `OnEnable→Rebuild` before `Dsl` is set (plain field, no rebuild-on-set, `NMRenderer.cs:33,64-67,90-98`), and `Output` is only assigned in `LateUpdate`/`RenderFrame` (`:165,:173`). **Fix:** `r.Dsl=…; r.EffectDefinitions=…; r.Rebuild(); r.RenderFrame(0f);` before reading `Output`; document the lifecycle.
4. **Mandatory Linear color space undocumented.** Engine forces `RenderTextureReadWrite.Linear`/ARGBHalf non-sRGB (`TextureStore.cs:185-186`, `NMPipeline.cs:507-508`); a Gamma project (Built-in default) silently renders wrong. Stated only in the porter doc. **Fix:** a top-of-README **Requirements**: "Player ▸ Color Space = Linear; a Gamma project renders incorrectly."
5. **`media` ships but can't render; no input API.** `README.md:88` calls `synth/media` "out of scope," yet `Effects/synth/media.json` ships (`starter:true`) with no shader → "Shader not found". There is **no host texture/camera/video input** anywhere in `Runtime/`. **The package is output-only.** **Fix:** state there is no input path, mark `media()` unsupported, reconcile/remove the stub.
6. **Live DSL is the headline API but explicitly unverified.** `NMRenderer.cs:104-105` / `DslCompiler.cs:146`: `TODO(verify): … validate via parity/ before relying on it`, while `ARCHITECTURE.md:38-39` / `README.md:43-44` assert it is validated. **Fix:** distinguish **GraphJson** (verified, recommended) vs **live Dsl** (early/unverified); scope the "validated" claims to the GraphJson path.
7. **Built-in/URP/HDRP claimed as fact; verified only on Built-in.** Asserted in package README:12-13, `NMRenderer.cs:6-7`, `ARCHITECTURE.md:50-51`; submission is `Graphics.ExecuteCommandBuffer` from `LateUpdate` (`NMPipeline.cs:269`), outside the SRP frame, with no SRP hooks. **Fix:** "verified on Built-in (Unity 6 / 6000.3.16f1); pipeline-agnostic, URP/HDRP unverified; renders to its own offscreen RT, not an SRP feature; presentation is integrator-owned."
8. **No performance guidance** despite ~4.2M-agent sims (`stateSize` cap 2048, `NMPipeline.cs:140-148`), fluid/feedback, 3D raymarch, and `RenderCubemap` re-rendering the whole graph **6× per call** (`NMPipeline.cs:532-547`). **Fix:** a "Performance & cost" section naming the knobs (`RenderWidth/Height`, `stateSize`, `faceSize`) + low-res-first workflow.
9. **No troubleshooting / symptom→cause map** (magenta/black/"Shader not found"/wrong colors are silent or log-only). **Fix:** a symptom→cause→fix table.
10. **Editor-only vs build-safe boundaries unstated.** `EffectsDirectory`/`LoadMeshFromFile` use `System.IO` (not build-safe); build-safe paths are `EffectDefinitions[]`/`LoadMesh(TextAsset)`; mesh `.obj`s aren't bundled (3D/mesh effects silently render nothing); IL2CPP/AOT never addressed.

## Should-fix (medium)

- `GraphJson` input undocumented (the safest path, takes precedence, `NMRenderer.cs:28-29,92-93`).
- Public host API undocumented: `Resize`/`Rebuild`/`RenderFrame`/`SetUniform` (numeric-only)/`LoadMesh*`, fields `RenderWidth/Height/Animate/AnimationDuration`, and `NMPipeline.PresentTo`/`GetOutput(name)`/`RenderCubemap`. Cubemap output has zero consumer-doc mention despite shipping.
- Shader Graph (`com.unity.shadergraph`) is an undeclared prerequisite for the node path — state it as a path-2 requirement with min version (do **not** add a hard `dependencies` entry — that would force path-1 users to pull SG).
- Unity version mismatch: `package.json` declares `2021.3`, only `6000.3.16f1` is verified.
- No single "supported vs not-yet-supported" table (`skipIf`/`runIf` inert; `if`/loops throw; automation uniforms ignored; tiled export no-op; `write3d` lane staged).
- Install routes incomplete — only "from disk" documented; add the git-URL route with the subfolder query (`…git?path=unity/com.noisemaker.hlsl#<tag>`).
- `Output`/surface lifetime: live RT recreated on `Resize()`/`Rebuild()`, nulled on disable — re-fetch, don't cache.
- Per-frame execution model: renders every `LateUpdate` while `Animate=true` (always-on GPU cost); main-thread only.
- Lifecycle/disposal/memory/multi-instance; `RenderCubemap`'s returned RT must be `Release`d by the caller (`NMPipeline.cs:493`).
- Consumer-vs-contributor boundary unclear — the README sends integrators to edit `NMCore.hlsl` and run `parity/`.

## Accuracy corrections (verified 2026-06-20)

| Location | Says | Correct |
|---|---|---|
| `README.md:60` | "all **180** shaders compile" | **183** effect shaders (185 incl. `NMBlit`/`NMCubeEquirect`) — or drop the number |
| `README.md:85` | "**179 / 180**" coverage | **184** effect-definition JSONs (183 with a renderable shader; `media` is definition-only) |
| `README.md:86` | synth 28 · mixer 14 · filter3d 1 · render 9 | synth **29** · mixer **15** · filter3d **2** · render **11** (filter 90, classicNoisedeck 20, points 10, synth3d 7 unchanged); render 11 includes the `loopBegin`/`loopEnd`/`meshLoader` control/infra passes |
| `README.md:88` | "only `media` out of scope" | `media.json` **ships** (`starter:true`) but has no shader — document as unbacked, not merely out of scope |
| `README.md:67`, `parity/README.md:39` | "**8/8** Tier-1 pixel-identical" | **12** parity programs now ship (adds `mashup`, `palette3d`, `renderCubemap3d`, `renderCubemapSurface`) |
| `ARCHITECTURE.md:62` | "`NMRenderTexture output`" | no such type — it is a `RenderTexture` (`NMRenderer.Output`) |
| `ARCHITECTURE.md:110-111` | "not yet compiled/rendered" | compiles + renders, verified on `6000.3.16f1` |
| `ARCHITECTURE.md:64-76` | 3D/mesh/agents/tiled-export "out of scope / staged" | shipped (`RenderCubemap`, `SetTileRegion`, `LoadMeshObj`, populated `points`/`synth3d`/`filter3d`); only the `write3d` compiler lane remains staged |

## Missing sections to add (priority order)

1. **Getting Started** — a happy path that actually renders (shader inclusion, Linear, `GraphJson` source, `Rebuild()`/first-frame, "display the output" recipe; presentation is integrator-owned and pipeline-dependent).
2. **Builds & platforms** — shader stripping/Always-Included, Editor-only vs build-safe, IL2CPP/AOT, Shader Model 4.5+ (excludes OpenGL ES/WebGL; requires float/half RTs).
3. **Requirements** — Unity version (manifest-min vs verified), Linear color space, Shader Graph as a path-2 prerequisite, render-pipeline notes.
4. **Host API reference** — `NMRenderer` fields/methods + advanced `NMPipeline` surface (incl. `RenderCubemap` flip contract).
5. **Troubleshooting** — symptom→cause→fix table.
6. **Performance & cost** and **Lifecycle & memory**.

## Ecosystem-norm cross-check

The Unity-ecosystem benchmark independently **confirmed** the structural gaps above (shader stripping/builds, Linear+ARGBHalf prereqs, RP-compat matrix, install routes, troubleshooting, Getting Started, lifecycle/disposal). Additional norm items worth adopting:

- In-package **`LICENSE.md`** (the manifest points at `../../LICENSE`, outside the package), **`CHANGELOG.md`** (Keep-a-Changelog + SemVer), and **`Third Party Notices.md`**; `package.json` help URLs (`documentationUrl`/`changelogUrl`/`licensesUrl`) + `displayName`/`description`/`keywords`.
- **`Samples~/`** with a one-click NMRenderer demo scene, registered in `package.json` `samples`.
- For eventual URP/HDRP support, prefer the SRP **`Blitter`** API over raw `CommandBuffer.Blit`.
- Custom Function node hygiene — wrap reusable nodes as **Sub Graphs**; state the `_float`/`_half` precision-suffix rule (the node `Name` omits the suffix).
- If a `Documentation~/` site is ever added, separate the four **Diátaxis** doc types.

## Corrections applied (2026-06-20)

The accuracy corrections, the package-README integrator sections (Requirements, runnable Quick Start, Builds, Troubleshooting, Performance, Host API, Lifecycle), the reconciled over-claims, and the ecosystem hygiene files (`LICENSE.md`, `CHANGELOG.md`, `package.json` fields) were applied in the same change set as this review. Follow-up items requiring **code** were then worked through:

- ✅ **Shader build auto-registrar** — shipped as `NMShaderInclusionBuildStep` (adds every
  `Noisemaker/*` shader to Always Included Shaders during a player build, restores after);
  verified in batchmode (collects 184 shaders, add→present→restore round-trips cleanly).
  This resolves the "builds render nothing" blocker.
- ⏳ **Host texture-input API**, **`Samples~` scene**, **URP/HDRP verification** — see the
  commit history / `noisemaker-hlsl-integration-readiness` notes for current status; the
  package remains output-only and verified on Built-in only until those land.
