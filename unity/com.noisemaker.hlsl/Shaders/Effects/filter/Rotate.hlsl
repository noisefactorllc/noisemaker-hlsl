#ifndef NM_ROTATE_INCLUDED
#define NM_ROTATE_INCLUDED

// =============================================================================
// Rotate.hlsl — filter/rotate, ported PIXEL-IDENTICALLY from the canonical WGSL:
//   shaders/effects/filter/rotate/wgsl/rot.wgsl
//
// Rotates the input texture by a specified angle (degrees), with aspect-correct
// centering and three wrap modes (mirror=0, repeat=1, clamp=2).
//
// WGSL main() summary:
//   let texSize = vec2<f32>(textureDimensions(inputTex));
//   var uv = pos.xy / texSize;
//   var angle = uniforms.rotation;
//   if (uniforms.speed != 0) { angle = angle + uniforms.time * 360.0 * f32(uniforms.speed); }
//   let aspect = texSize.x / texSize.y;
//   uv -= vec2<f32>(0.5);
//   uv.x = uv.x * aspect;
//   uv = rotate2D(-angle * TAU / 360.0) * uv;
//   uv.x = uv.x / aspect;
//   uv += vec2<f32>(0.5);
//   // wrap modes ...
//   return textureSample(inputTex, inputSampler, uv);
//
// PORTING-GUIDE notes:
//  * uv = fragCoord / textureDimensions(inputTex) — divides by the INPUT texture's
//    own size, NOT fullResolution. This is the canonical WGSL form.
//  * rotate2D helper is per-effect (mat2x2 column-major in WGSL -> float2x2 in HLSL;
//    both store (c,-s,s,c) in the same layout — row-major HLSL mul(m,v) is identical
//    to WGSL mat2x2 * vec2). See note below.
//  * WGSL modulo used for mirror/repeat wrap: `(a % b + b) % b` — use nm_mod (never
//    fmod) per PORTING-GUIDE rule H6.
//  * `time` comes from NMFullscreen.hlsl engine alias (_NM_Time).
//  * speed / wrap are declared as int uniforms (definition.js type:"int").
//  * WGSL rotate2D(angle) constructs mat2x2<f32>(c, -s, s, c).
//    In WGSL mat2x2<f32>(a,b,c,d) fills column-major: col0=(a,b), col1=(c,d).
//    So col0=(c,-s), col1=(s,c). Matrix-vector: uv' = (c*x + s*y, -s*x + c*y).
//    HLSL float2x2(c, -s, s, c) fills row-major: row0=(c,-s), row1=(s,c).
//    mul(float2x2, float2) computes: (row0·v, row1·v) = (c*x - s*y, s*x + c*y).
//    These differ! To match WGSL col-major * vec we must use mul(v, m) in HLSL
//    (row-vec post-multiply), or equivalently mul(transpose(m), v).
//    The transpose of float2x2(c,-s,s,c) is float2x2(c,s,-s,c), so:
//      HLSL: mul(float2x2(c, s, -s, c), uv)  matches WGSL col-major mat * vec.
//    Verified against GLSL: mat2(c,-s,s,c)*uv = (c*x-s*y, s*x+c*y) — same result.
//    So HLSL float2x2 rows (c,s),(-s,c) gives (c*x+s*y, -s*x+c*y) — wait, let's
//    be precise:
//      WGSL mat2x2<f32>(c,-s,s,c) * uv:
//        col0 = (c, -s), col1 = (s, c)
//        result.x = col0.x * uv.x + col1.x * uv.y = c*x + s*y
//        result.y = col0.y * uv.x + col1.y * uv.y = -s*x + c*y
//      HLSL mul(float2x2(c,s,-s,c), uv):
//        row0 = (c, s):  c*x + s*y  ✓
//        row1 = (-s, c): -s*x + c*y ✓
//    So nm_rotate2D uses float2x2(c, s, -s, c). // TODO(verify) matrix orientation
//  * No PRNG, no pcg — no NMCore primitives used here.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// Per-effect named uniforms (definition.js globals)
float rotation;   // degrees, default 45, min -180, max 180
int   wrap;       // 0=mirror 1=repeat 2=clamp, default 1
int   speed;      // integer -4..4, default 0

static const float NM_ROT_TAU = 6.283185307179586;

// rotate2D helper — ported verbatim from WGSL (col-major semantics, see above).
// Returns the equivalent HLSL row-major matrix that produces identical results
// when applied with mul(nm_rotate2D(a), uv).
float2x2 nm_rotate2D(float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    // float2x2 rows: (c, s), (-s, c)  →  mul(m, v) = (c*x+s*y, -s*x+c*y)
    // which matches WGSL mat2x2<f32>(c,-s,s,c) * v column-major multiply.
    return float2x2(c, s, -s, c);
}

// nm_rotate — core per-pixel evaluation.
// texSize: dimensions of inputTex (used for uv construction AND aspect).
// uv: pos.xy / texSize (already computed in the shader pass).
// Returns rotated sample UV (caller must sample inputTex at the returned UV).
float2 nm_rotate_uv(float2 uv, float2 texSize)
{
    // Animate rotation
    float angle = rotation;
    [branch]
    if (speed != 0)
    {
        // WGSL: angle = angle + uniforms.time * 360.0 * f32(uniforms.speed);
        angle = angle + time * 360.0 * (float)speed;
    }

    // Center, correct aspect, rotate, uncorrect, uncenter
    float aspect = texSize.x / texSize.y;
    float2 center = float2(0.5, 0.5);
    uv -= center;
    uv.x = uv.x * aspect;
    uv = mul(nm_rotate2D(-angle * NM_ROT_TAU / 360.0), uv);
    uv.x = uv.x / aspect;
    uv += center;

    // Apply wrap mode
    // WGSL wrap==0 (mirror): uv = abs(((uv + 1.0) % 2.0 + 2.0) % 2.0 - 1.0)
    // WGSL wrap==1 (repeat): uv = (uv % 1.0 + 1.0) % 1.0
    // WGSL wrap==2 (clamp):  uv = clamp(uv, 0.0, 1.0)
    // nm_mod(a,b) = a - b*floor(a/b) — matches WGSL modulo (floors toward -inf)
    [branch]
    if (wrap == 0)
    {
        // mirror
        uv = abs(nm_mod(nm_mod(uv + float2(1.0, 1.0), float2(2.0, 2.0)) + float2(2.0, 2.0), float2(2.0, 2.0)) - float2(1.0, 1.0));
    }
    else if (wrap == 1)
    {
        // repeat
        uv = nm_mod(nm_mod(uv, float2(1.0, 1.0)) + float2(1.0, 1.0), float2(1.0, 1.0));
    }
    else
    {
        // clamp
        uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    return uv;
}

#endif // NM_ROTATE_INCLUDED
