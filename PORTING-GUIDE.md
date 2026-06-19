# Noisemaker → HLSL Shader Porting Guide

The authoritative rulebook for porting a Noisemaker effect shader to Unity HLSL
**pixel-identically**. Derived from reference specs `reference/07` and `reference/08`.
Read this before porting any shader. Every rule here is a parity requirement, not a
style preference.

## Golden rules

1. **Port from the WGSL source, not the GLSL.** WGSL is top-left / D3D-oriented,
   exactly like Unity HLSL. GLSL is bottom-left and reconciles Y elsewhere. Porting
   from WGSL means **no per-effect Y flip** is needed. Use the GLSL only to
   disambiguate when the WGSL is unclear.
2. **Port helpers verbatim, per effect.** `pcg`/`prng`/`random` are the *only*
   shared primitives (in `NMCore.hlsl`). Everything else — `hsv2rgb`, `rgb2hsv`,
   `rotate2D`, distance metrics, `smin`, `shape` — is frequently **different**
   between effects despite identical names. Copy each effect's own version inline.
   Never substitute a "generic" version.
3. **Do not simplify or reassociate arithmetic.** The references contain
   deliberately redundant expressions (e.g. `catmullRom3`'s partially-cancelling
   terms). Reproduce them literally. Disable fast-math reassociation.
4. **Full 32-bit float only.** Never `half`/`min16float`. PCG and `asuint(frac(s))`
   are bit-sensitive.

## Translation table (GLSL/WGSL → HLSL)

| Concept | GLSL | WGSL | HLSL | Notes |
|---|---|---|---|---|
| vectors | `vec2/3/4`,`ivecN`,`uvecN` | `vecN<f32>` | `float2/3/4`,`intN`,`uintN` | |
| construct splat | `vec3(x)` | `vec3<f32>(x)` | `float3(x,x,x)` or `(float3)x` | |
| lerp | `mix` | `mix` | `lerp` | |
| frac | `fract` | `fract` | `frac` | = `x-floor(x)` |
| **float mod** | `mod(a,b)` | `modulo()`/`a-b*floor` | **`nm_mod(a,b)`** | NEVER `fmod` (H6) |
| int `%` | trunc→0 | trunc→0 | `%` trunc→0 | use `nm_positiveModulo` for the +mod fix |
| atan2 | `atan(y,x)` | `atan2(a,b)` | `atan2(a,b)` | **copy source arg order literally** (H3) |
| pow2 | `pow(2.0,float(i))` | `pow(2.0,f32(i))` | `exp2((float)i)` or `pow(2.0,i)` | |
| float→uint | `uint(f)`,`uvec3(p)` | `u32(f)`,`vec3<u32>` | `(uint)f`,`(uint3)p` | **truncation, NOT `asuint`** |
| int→uint reinterpret | `uint(i)` (i may be neg) | `u32(i)` | `(uint)i` | two's-complement preserved |
| **float bits→uint** | `floatBitsToUint(f)` | `bitcast<u32>(f)` | **`asuint(f)`** | bit reinterpret (jitter) |
| uint bits→float | `uintBitsToFloat` | `bitcast<f32>` | `asfloat` | |
| uint→float numeric | `float(u)` | `f32(u)` | `(float)u` | round-to-nearest |
| uint literals | `1664525u`,`0x..u` | same | `1664525u`,`0x..u` | wraps mod 2^32 |
| logical shift | `v >> 16u` | `v >> 16u` | `v >> 16u` | unsigned |
| ternary / select | `c ? a : b` | `select(b,a,c)` | `c ? a : b` | WGSL `select(false,true,cond)` — reversed! |
| texture decl | `uniform sampler2D t` | `texture_2d<f32>`+`sampler` | `Texture2D t; SamplerState sampler_t;` | |
| sample | `texture(t,uv)` | `textureSample(t,s,uv)` | `t.Sample(sampler_t, uv)` | linear, clamp, **non-sRGB** |
| tex size | `textureSize(t,0)` | `textureDimensions(t)` | `uint w,h; t.GetDimensions(w,h)` | |
| frag coord | `gl_FragCoord.xy` (bottom-left) | `position.xy` (top-left) | **`NM_FragCoord(i)`** | top-left, +0.5 centered |
| out color | `out vec4 fragColor` | `@location(0)` return | `return float4` : `SV_Target` | |
| struct member sep | `;` | `,` | `;` | |

## Uniform binding model

- We bind per-effect uniforms as **individual named uniforms** (the GLSL style),
  NOT the WGSL packed `array<vec4,N> data[]`. Values are identical; this is
  Shader-Graph-friendly. Declare each as a bare global matching the reference
  `globals[*].uniform` name (e.g. `float scaleX; int seed; int octaves;`).
- Booleans: declare `int`/`float` and test as the reference does. WGSL uses
  `data[..] > 0.5`; passing `1.0/0.0` and testing `> 0.5` is exact. Prefer matching
  the WGSL comparison.
- Ints: the reference does `i32(float)` truncation. Declaring an HLSL `int` uniform
  set from an integer value is exact for the non-negative ranges used.
- Engine globals (`resolution`,`time`,`tileOffset`,`fullResolution`,`renderScale`,
  `aspectRatio`) are provided by `NMFullscreen.hlsl` via `#define` aliases — use the
  bare names directly.
- Compile-time `#define`s (`NOISE_TYPE`,`LOOP_OFFSET`): the reference used these only
  to avoid an ANGLE→D3D perf stall; they are **not** correctness-relevant. In HLSL,
  declare them as `int` uniforms and branch at runtime with `[branch]` (this is what
  the WGSL path already does — it keeps all variants and relies on const-folding).
  Default values when unset: `NOISE_TYPE=10` (simplex), `LOOP_OFFSET=300`.

## Coordinate & sampling parity (the #1 hazard class)

- `st = (NM_GlobalCoord(i)) / fullResolution.y` — **divide by HEIGHT (.y)**, not
  width and not both axes. X then spans `[0, aspect]` (H13).
- Canonical origin is top-left (WGSL). Ported-from-WGSL bodies need no flip. If the
  parity harness shows a vertical mirror on a given graphics API, flip once via
  `#define NM_FLIP_Y 1` (handled in `NMFullscreen.hlsl`) — never per-effect.
- Render targets are **linear half-float** (`RenderTextureFormat.ARGBHalf`), 4-channel.
  No sRGB encode/decode in the pipeline. Ensure the RenderTexture is created with
  `RenderTextureReadWrite.Linear` and the project does not auto-sRGB it (H2, H7).
- Samplers: bilinear, clamp-to-edge by default (repeat only where the effect tiles).
  Declare `SamplerState` explicitly; do not rely on Unity's `sampler2D` sRGB path.
- Pixel center is `+0.5` in GLSL/WGSL/HLSL alike.

## Numeric-exactness hazards (bit-for-bit)

- PCG divisor is `4294967295.0` (= `float(0xffffffffu)`), **not** `2^32` (H11).
- `asuint(frac(s))` for jitter is a **bit reinterpret**; `(uint)f` for lattice coords
  is a **numeric truncation**. They are different ops — match each exactly.
- Cube-root / magic exponents: use the full-precision literal that appears in the
  WGSL (e.g. `0.3333333333333`), not a truncated one.
- `aspectRatio` in GLSL is a textual macro `fullResolution.x / fullResolution.y`;
  always treat as a precomputed float (NMFullscreen aliases it parenthesized).
- Keep loop bounds inclusive exactly as written (`i <= radius`, `i <= oct`, `<= 2`).

## Per-effect output checklist

For each ported effect produce, under `unity/com.noisemaker.hlsl/`:
1. `Shaders/Effects/<ns>/<Effect>.hlsl` — the core `nm_<effect>(...)` function(s),
   ported verbatim from WGSL, includes `NMCore.hlsl` only (no shared color/dist libs).
2. `Shaders/Effects/<ns>/<Effect>.shader` — a Unity shader with the fullscreen pass
   (`NMVertFullscreen`) calling the core fn; one SubShader pass per render pass.
   For 2-pass effects (e.g. blur H/V) emit one pass each. Render state: `ZWrite Off
   ZTest Always Cull Off`; additive deposit passes use `Blend One One`.
3. `Effects/<ns>/<effect>.json` — the effect definition for the C# runtime
   (name/namespace/func/globals/passes/textures), converted from `definition.js`.
4. `ShaderGraph/CustomFunctions/<Effect>.hlsl` — a `void NM_<Effect>_float(...,
   out float4 Out)` wrapper exposing named inputs for a Shader Graph Custom Function
   node (generators only; multi-pass effects ship as a runtime-rendered Texture2D).

Validate every port with the parity harness in `parity/` (golden = reference GPU
render via Playwright; compare with `parity/compare.py`, tolerance per effect).
