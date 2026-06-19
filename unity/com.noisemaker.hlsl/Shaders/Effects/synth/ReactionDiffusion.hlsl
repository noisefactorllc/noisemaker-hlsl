#ifndef NM_EFFECT_REACTIONDIFFUSION_INCLUDED
#define NM_EFFECT_REACTIONDIFFUSION_INCLUDED

// =============================================================================
// ReactionDiffusion.hlsl — synth/reactionDiffusion (func: "reactionDiffusion")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources:
//   shaders/effects/synth/reactionDiffusion/wgsl/rdFb.wgsl (progName "rdFb")
//   shaders/effects/synth/reactionDiffusion/wgsl/rd.wgsl   (progName "rd")
//
// Gray-Scott reaction-diffusion. MULTI-PASS, FEEDBACK:
//   Pass "simulate" (program rdFb): runs the Gray-Scott update step on the
//     low-res persistent state texture `global_rd_state`. It SAMPLES ITS OWN
//     PREVIOUS OUTPUT (bufTex == global_rd_state) and writes back to
//     global_rd_state. repeat:"iterations" — the runtime ping-pongs the global
//     surface per iteration (§10.6), so each iteration reads the prior write.
//     The shader has NO iteration index (no _iteration uniform injected).
//   Pass "render" (program rd): formats the simulation state (channel .g) into
//     grayscale output, with optional smoothing modes and input blend.
//
// NOTE: this effect is multi-pass with a persistent feedback state texture and
// ships as a runtime-rendered Texture2D. The C# runtime drives the two passes,
// runs "simulate" N=iterations times into the ping-ponged global_rd_state, then
// "render" once into outputTex. No Shader Graph Custom Function wrapper.
//
// PORTING-GUIDE notes / hazards handled:
//  * Ported from WGSL (top-left, canonical). No per-effect Y flip (H1/H8).
//  * Helpers ported verbatim inline (lp/map/lum/hash for rdFb; modulo/quadratic3/
//    bicubic4/catmullRom3/catmullRom4/quadratic/catmullRom3x3/bicubic/
//    catmullRom4x4/cosineMix for rd). nm_mod is NOT used: the WGSL `modulo` is
//    only referenced indirectly and the math here uses none of it — but the
//    WGSL `modulo` helper is reproduced verbatim for fidelity (unused, like src).
//  * WGSL `textureSampleLevel(tex, samp, uv, 0.0)` -> Texture2D.SampleLevel(s, uv, 0).
//  * WGSL `textureLoad(tex, coordI32, 0)` -> Texture2D.Load(int3(coord, 0))
//    (integer fetch, no filtering). `textureDimensions(tex, 0)` -> GetDimensions.
//  * WGSL `vec2<i32>(...)` / `i32(f32)` -> int2 / (int)f : numeric TRUNCATION.
//  * `pos.xy` (@builtin(position), top-left, +0.5) -> NM_FragCoord(i).
//  * rdFb: weight is already *0.01 in WGSL (`data[2].y*0.01`) then mix(f,val,
//    weight). (GLSL applies *0.01 at the mix site; identical result.) We follow
//    WGSL exactly.
//  * rdFb: `time`/`zoom` are read but mathematically unused (matches WGSL).
//  * Sampler: linear, clamp-to-edge, non-sRGB (H7) — set in the .shader.
//  * Full 32-bit float only (PCG/hash bit-sensitive) (H4).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input textures + samplers (one SamplerState per distinct sampler) -------
// Reference WGSL binds a single `samp` sampler shared by both pass inputs.
// rdFb inputs: bufTex (=global_rd_state, persistent feedback), inputTex (=tex).
// rd   inputs: fbTex  (=global_rd_state),                       inputTex (=tex).
// We declare each distinct sampled texture; bufTex and fbTex are the SAME
// physical global_rd_state surface but bound under different reference sampler
// names per pass, so we declare both. The runtime rebinds per pass.
Texture2D    bufTex;        // rdFb: global_rd_state (read previous state)
SamplerState sampler_bufTex;
Texture2D    fbTex;         // rd:   global_rd_state (read final state)
SamplerState sampler_fbTex;
Texture2D    inputTex;      // both: external input surface (globals.tex)
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) ------
// rdFb consumes: resolution, time, zoom, feed, kill, rate1, rate2, speed,
//                weight, sourceF, sourceK, sourceR1, sourceR2, resetState, seed.
// rd   consumes: resolution, time, inputIntensity, smoothing.
// resolution/time are engine globals (NMFullscreen). The rest are named below.
float zoom;             // globals.zoom (int dropdown) — read, math-unused in rdFb
float feed;             // globals.feed   [10,110]
float kill;             // globals.kill   [45,70]
float rate1;            // globals.rate1  [50,120]
float rate2;            // globals.rate2  [20,50]
float speed;            // globals.speed  [10,145]
float weight;           // globals.weight [0,100]
int   sourceF;          // globals.sourceF dropdown
int   sourceK;          // globals.sourceK dropdown
int   sourceR1;         // globals.sourceR1 dropdown
int   sourceR2;         // globals.sourceR2 dropdown
float resetState;       // globals.resetState boolean (1.0/0.0; test > 0.5)
int   seed;             // globals.seed [1,100]

float inputIntensity;   // globals.inputIntensity [0,100]
int   smoothing;        // globals.smoothing dropdown

// =============================================================================
// Program "rdFb" — Gray-Scott feedback/update pass. Verbatim from rdFb.wgsl.
// =============================================================================

// WGSL: fn modulo(a,b) -> a - b*floor(a/b). Reproduced verbatim (unused, as src).
float nm_rdfb_modulo(float a, float b)
{
    return a - b * floor(a / b);
}

// WGSL lp(): fixed 1px Laplacian-ish neighbourhood (matches GLSL).
float3 nm_rdfb_lp(Texture2D tex, SamplerState samp, float2 uv, float2 size)
{
    float pixelStep = 1.0;

    float3 val = float3(0.0, 0.0, 0.0);
    val = val + tex.SampleLevel(samp, (uv + float2(-pixelStep, -pixelStep)) / size, 0.0).rgb * 0.05;
    val = val + tex.SampleLevel(samp, (uv + float2(0.0, -pixelStep)) / size, 0.0).rgb * 0.2;
    val = val + tex.SampleLevel(samp, (uv + float2(pixelStep, -pixelStep)) / size, 0.0).rgb * 0.05;
    val = val + tex.SampleLevel(samp, (uv + float2(-pixelStep, 0.0)) / size, 0.0).rgb * 0.2;
    val = val + tex.SampleLevel(samp, (uv + float2(0.0, 0.0)) / size, 0.0).rgb * -1.0;
    val = val + tex.SampleLevel(samp, (uv + float2(pixelStep, 0.0)) / size, 0.0).rgb * 0.2;
    val = val + tex.SampleLevel(samp, (uv + float2(-pixelStep, pixelStep)) / size, 0.0).rgb * 0.05;
    val = val + tex.SampleLevel(samp, (uv + float2(0.0, pixelStep)) / size, 0.0).rgb * 0.2;
    val = val + tex.SampleLevel(samp, (uv + float2(pixelStep, pixelStep)) / size, 0.0).rgb * 0.05;
    return val;
}

// WGSL map(): linear remap.
float nm_rdfb_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// WGSL lum(): Rec.709 luma.
float nm_rdfb_lum(float3 color)
{
    return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

// WGSL hash(): 2D -> 1D hash for sparse seeding.
float nm_rdfb_hash(float2 p)
{
    float2 p2 = frac(p * float2(0.1031, 0.1030));
    p2 = p2 + dot(p2, p2.yx + 33.33);
    return frac((p2.x + p2.y) * p2.x);
}

float4 frag_rdFb(NMVaryings i) : SV_Target
{
    // WGSL: resolution = data[0].xy; time = data[0].z (unused);
    //       zoom = data[0].w; seed = data[3].w.
    float fseed = (float)seed;
    float2 pos = NM_FragCoord(i);  // @builtin(position).xy analog (top-left, +0.5)

    uint tw, th;
    bufTex.GetDimensions(tw, th);
    float2 texSize = float2((float)tw, (float)th);

    float4 tex = bufTex.SampleLevel(sampler_bufTex, pos / texSize, 0.0);
    float a = tex.r;
    float b = tex.g;

    // Empty-buffer (first frame) or reset detection.
    bool bufferIsEmpty = (tex.r == 0.0 && tex.g == 0.0 && tex.b == 0.0 && tex.a == 0.0);
    bool reset = (resetState > 0.5);

    if (bufferIsEmpty || reset)
    {
        // Initialize: A=1 everywhere, B=1 at sparse random locations.
        a = 1.0;
        b = 0.0;
        if (nm_rdfb_hash(pos + float2(fseed, fseed)) > 0.99)
        {
            b = 1.0;
        }
        return float4(a, b, 0.0, 1.0);
    }

    float3 color = nm_rdfb_lp(bufTex, sampler_bufTex, pos, texSize);

    float2 prevFrameCoord = pos / texSize;
    float3 prevFrame = inputTex.SampleLevel(sampler_inputTex, prevFrameCoord, 0.0).rgb;
    float prevLum = nm_rdfb_lum(prevFrame);

    // WGSL: f=data[1].x*0.001; k=data[1].y*0.001; r1=data[1].z*0.01;
    //       r2=data[1].w*0.01; s=data[2].x*0.01; weight=data[2].y*0.01.
    float f = feed * 0.001;
    float k = kill * 0.001;
    float r1 = rate1 * 0.01;
    float r2 = rate2 * 0.01;
    float s = speed * 0.01;
    float w = weight * 0.01;
    int sF = sourceF;
    int sK = sourceK;
    int sR1 = sourceR1;
    int sR2 = sourceR2;

    if (sF > 0)
    {
        float val = prevLum;
        if (sF == 2) {
            val = 1.0 - prevLum;
        } else if (sF == 3) {
            val = prevFrame.r;
        } else if (sF == 4) {
            val = prevFrame.g;
        } else if (sF == 5) {
            val = prevFrame.b;
        } else if (sF == 6) {
            val = nm_rdfb_map(prevLum, 0.0, 1.0, 0.01, 0.11);
            f = lerp(f, val, w);
        }
        if (sF != 6) {
            val = nm_rdfb_map(val, 0.0, 1.0, 0.01, 0.11);
            f = val;
        }
    }

    if (sK > 0)
    {
        float val = prevLum;
        if (sK == 2) {
            val = 1.0 - prevLum;
        } else if (sK == 3) {
            val = prevFrame.r;
        } else if (sK == 4) {
            val = prevFrame.g;
        } else if (sK == 5) {
            val = prevFrame.b;
        } else if (sK == 6) {
            val = nm_rdfb_map(prevLum, 0.0, 1.0, 0.045, 0.07);
            k = lerp(k, val, w);
        }
        if (sK != 6) {
            val = nm_rdfb_map(val, 0.0, 1.0, 0.045, 0.07);
            k = val;
        }
    }

    if (sR1 > 0)
    {
        float val = prevLum;
        if (sR1 == 2) {
            val = 1.0 - prevLum;
        } else if (sR1 == 3) {
            val = prevFrame.r;
        } else if (sR1 == 4) {
            val = prevFrame.g;
        } else if (sR1 == 5) {
            val = prevFrame.b;
        } else if (sR1 == 6) {
            val = nm_rdfb_map(prevLum, 0.0, 1.0, 0.5, 1.2);
            r1 = lerp(r1, val, w);
        }
        if (sR1 != 6) {
            val = nm_rdfb_map(val, 0.0, 1.0, 0.5, 1.2);
            r1 = val;
        }
    }

    if (sR2 > 0)
    {
        float val = prevLum;
        if (sR2 == 2) {
            val = 1.0 - prevLum;
        } else if (sR2 == 3) {
            val = prevFrame.r;
        } else if (sR2 == 4) {
            val = prevFrame.g;
        } else if (sR2 == 5) {
            val = prevFrame.b;
        } else if (sR2 == 6) {
            val = nm_rdfb_map(prevLum, 0.0, 1.0, 0.2, 0.5);
            r2 = lerp(r2, val, w);
        }
        if (sR2 != 6) {
            val = nm_rdfb_map(val, 0.0, 1.0, 0.2, 0.5);
            r2 = val;
        }
    }

    float a2 = clamp(a + (r1 * color.r - a * b * b + f * (1.0 - a)) * s, 0.0, 1.0);
    float b2 = clamp(b + (r2 * color.g + a * b * b - (k + f) * b) * s, 0.0, 1.0);

    return float4(a2, b2, 0.0, 1.0);
}

// =============================================================================
// Program "rd" — display/format pass. Verbatim from rd.wgsl.
// =============================================================================

// WGSL quadratic3 (quadratic B-spline weights).
float4 nm_rd_quadratic3(float4 p0, float4 p1, float4 p2, float t)
{
    float t2 = t * t;
    return p0 * 0.5 * (1.0 - t) * (1.0 - t) +
           p1 * 0.5 * (-2.0 * t2 + 2.0 * t + 1.0) +
           p2 * 0.5 * t2;
}

// WGSL bicubic4 (cubic B-spline weights).
float4 nm_rd_bicubic4(float4 p0, float4 p1, float4 p2, float4 p3, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    float b0 = (1.0 - t) * (1.0 - t) * (1.0 - t) / 6.0;
    float b1 = (3.0 * t3 - 6.0 * t2 + 4.0) / 6.0;
    float b2 = (-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0;
    float b3 = t3 / 6.0;

    return p0 * b0 + p1 * b1 + p2 * b2 + p3 * b3;
}

// WGSL catmullRom3 (3-point Catmull-Rom; deliberately redundant `m` terms — do
// NOT simplify, PORTING-GUIDE Golden Rule 3).
float4 nm_rd_catmullRom3(float4 p0, float4 p1, float4 p2, float t)
{
    float t2 = t * t;
    float t3 = t2 * t;

    float4 m = 0.5 * (p2 - p0);

    return (2.0 * t3 - 3.0 * t2 + 1.0) * p1 +
           (t3 - 2.0 * t2 + t) * m +
           (-2.0 * t3 + 3.0 * t2) * p2 +
           (t3 - t2) * m;
}

// WGSL catmullRom4 (4-point Catmull-Rom, Horner form). Copy arithmetic literally.
float4 nm_rd_catmullRom4(float4 p0, float4 p1, float4 p2, float4 p3, float t)
{
    return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
}

// WGSL quadratic() — 3x3 B-spline upsample.
float4 nm_rd_quadratic(Texture2D tex, SamplerState samp, float2 uv, float2 texelSize)
{
    float2 uv2 = uv + texelSize;
    float2 texCoord = uv2 / texelSize;
    float2 baseCoord = floor(texCoord - 0.5);
    float2 fr = frac(texCoord - 0.5);

    float4 v00 = tex.SampleLevel(samp, (baseCoord + float2(-0.5, -0.5)) * texelSize, 0.0);
    float4 v10 = tex.SampleLevel(samp, (baseCoord + float2( 0.5, -0.5)) * texelSize, 0.0);
    float4 v20 = tex.SampleLevel(samp, (baseCoord + float2( 1.5, -0.5)) * texelSize, 0.0);

    float4 v01 = tex.SampleLevel(samp, (baseCoord + float2(-0.5,  0.5)) * texelSize, 0.0);
    float4 v11 = tex.SampleLevel(samp, (baseCoord + float2( 0.5,  0.5)) * texelSize, 0.0);
    float4 v21 = tex.SampleLevel(samp, (baseCoord + float2( 1.5,  0.5)) * texelSize, 0.0);

    float4 v02 = tex.SampleLevel(samp, (baseCoord + float2(-0.5,  1.5)) * texelSize, 0.0);
    float4 v12 = tex.SampleLevel(samp, (baseCoord + float2( 0.5,  1.5)) * texelSize, 0.0);
    float4 v22 = tex.SampleLevel(samp, (baseCoord + float2( 1.5,  1.5)) * texelSize, 0.0);

    float4 y0 = nm_rd_quadratic3(v00, v10, v20, fr.x);
    float4 y1 = nm_rd_quadratic3(v01, v11, v21, fr.x);
    float4 y2 = nm_rd_quadratic3(v02, v12, v22, fr.x);

    return nm_rd_quadratic3(y0, y1, y2, fr.y);
}

// WGSL catmullRom3x3() — 9-tap Catmull-Rom upsample.
float4 nm_rd_catmullRom3x3(Texture2D tex, SamplerState samp, float2 uv, float2 texelSize)
{
    float2 uv2 = uv + texelSize;
    float2 texCoord = uv2 / texelSize;
    float2 baseCoord = floor(texCoord - 1.0);
    float2 fr = frac(texCoord - 1.0);

    float4 v00 = tex.SampleLevel(samp, (baseCoord + float2(-0.5, -0.5)) * texelSize, 0.0);
    float4 v10 = tex.SampleLevel(samp, (baseCoord + float2( 0.5, -0.5)) * texelSize, 0.0);
    float4 v20 = tex.SampleLevel(samp, (baseCoord + float2( 1.5, -0.5)) * texelSize, 0.0);

    float4 v01 = tex.SampleLevel(samp, (baseCoord + float2(-0.5,  0.5)) * texelSize, 0.0);
    float4 v11 = tex.SampleLevel(samp, (baseCoord + float2( 0.5,  0.5)) * texelSize, 0.0);
    float4 v21 = tex.SampleLevel(samp, (baseCoord + float2( 1.5,  0.5)) * texelSize, 0.0);

    float4 v02 = tex.SampleLevel(samp, (baseCoord + float2(-0.5,  1.5)) * texelSize, 0.0);
    float4 v12 = tex.SampleLevel(samp, (baseCoord + float2( 0.5,  1.5)) * texelSize, 0.0);
    float4 v22 = tex.SampleLevel(samp, (baseCoord + float2( 1.5,  1.5)) * texelSize, 0.0);

    float4 y0 = nm_rd_catmullRom3(v00, v10, v20, fr.x);
    float4 y1 = nm_rd_catmullRom3(v01, v11, v21, fr.x);
    float4 y2 = nm_rd_catmullRom3(v02, v12, v22, fr.x);

    return nm_rd_catmullRom3(y0, y1, y2, fr.y);
}

// WGSL bicubic() — 16-tap cubic B-spline upsample.
float4 nm_rd_bicubic(Texture2D tex, SamplerState samp, float2 uv, float2 texelSize)
{
    float2 uv2 = uv + texelSize;
    float2 texCoord = uv2 / texelSize;
    float2 baseCoord = floor(texCoord - 1.0);
    float2 fr = frac(texCoord - 1.0);

    float4 row0 = nm_rd_bicubic4(
        tex.SampleLevel(samp, (baseCoord + float2(-0.5, -0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 0.5, -0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 1.5, -0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 2.5, -0.5)) * texelSize, 0.0),
        fr.x
    );

    float4 row1 = nm_rd_bicubic4(
        tex.SampleLevel(samp, (baseCoord + float2(-0.5,  0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 0.5,  0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 1.5,  0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 2.5,  0.5)) * texelSize, 0.0),
        fr.x
    );

    float4 row2 = nm_rd_bicubic4(
        tex.SampleLevel(samp, (baseCoord + float2(-0.5,  1.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 0.5,  1.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 1.5,  1.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 2.5,  1.5)) * texelSize, 0.0),
        fr.x
    );

    float4 row3 = nm_rd_bicubic4(
        tex.SampleLevel(samp, (baseCoord + float2(-0.5,  2.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 0.5,  2.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 1.5,  2.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 2.5,  2.5)) * texelSize, 0.0),
        fr.x
    );

    return nm_rd_bicubic4(row0, row1, row2, row3, fr.y);
}

// WGSL catmullRom4x4() — 16-tap Catmull-Rom upsample.
float4 nm_rd_catmullRom4x4(Texture2D tex, SamplerState samp, float2 uv, float2 texelSize)
{
    float2 uv2 = uv + texelSize;
    float2 texCoord = uv2 / texelSize;
    float2 baseCoord = floor(texCoord - 1.0);
    float2 fr = frac(texCoord - 1.0);

    float4 row0 = nm_rd_catmullRom4(
        tex.SampleLevel(samp, (baseCoord + float2(-0.5, -0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 0.5, -0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 1.5, -0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 2.5, -0.5)) * texelSize, 0.0),
        fr.x
    );

    float4 row1 = nm_rd_catmullRom4(
        tex.SampleLevel(samp, (baseCoord + float2(-0.5,  0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 0.5,  0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 1.5,  0.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 2.5,  0.5)) * texelSize, 0.0),
        fr.x
    );

    float4 row2 = nm_rd_catmullRom4(
        tex.SampleLevel(samp, (baseCoord + float2(-0.5,  1.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 0.5,  1.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 1.5,  1.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 2.5,  1.5)) * texelSize, 0.0),
        fr.x
    );

    float4 row3 = nm_rd_catmullRom4(
        tex.SampleLevel(samp, (baseCoord + float2(-0.5,  2.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 0.5,  2.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 1.5,  2.5)) * texelSize, 0.0),
        tex.SampleLevel(samp, (baseCoord + float2( 2.5,  2.5)) * texelSize, 0.0),
        fr.x
    );

    return nm_rd_catmullRom4(row0, row1, row2, row3, fr.y);
}

// WGSL cosineMix(): cosine-eased interpolation. Full-precision PI literal.
float nm_rd_cosineMix(float a, float b, float t)
{
    float amount = (1.0 - cos(t * 3.141592653589793)) * 0.5;
    return lerp(a, b, amount);
}

float4 frag_rd(NMVaryings i) : SV_Target
{
    // WGSL: resolution = data[0].xy; smoothing = i32(data[3].w);
    //       inputIntensity = data[1].x * 0.01.
    float2 pos = NM_FragCoord(i);  // @builtin(position).xy analog
    float2 res = resolution;       // engine global
    int sm = smoothing;
    float inputIntens = inputIntensity * 0.01;

    float intensity = 1.0;

    if (sm == 0)
    {
        // constant (nearest) — textureLoad
        uint tw, th;
        fbTex.GetDimensions(tw, th);
        int2 texSizeI = int2((int)tw, (int)th);
        float2 texSizeF = float2((float)texSizeI.x, (float)texSizeI.y);
        int2 coord = (int2)floor(pos * texSizeF / res);
        int2 clamped = clamp(coord, int2(0, 0), texSizeI - int2(1, 1));
        intensity = clamp(fbTex.Load(int3(clamped, 0)).g, 0.0, 1.0);
    }
    else if (sm == 2)
    {
        // hermite (smoothstep)
        uint tw, th;
        fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelPos = (pos * texSize / res) - float2(0.5, 0.5);
        float2 base = floor(texelPos);
        float2 weights = frac(texelPos);
        float2 nxt = base + float2(1.0, 1.0);

        int2 texSizeI = int2((int)tw, (int)th);
        int2 minIdx = int2(0, 0);
        int2 maxIdx = texSizeI - int2(1, 1);

        int2 baseIdx = clamp((int2)base, minIdx, maxIdx);
        int2 nextIdx = clamp((int2)nxt, minIdx, maxIdx);

        float v00 = fbTex.Load(int3(baseIdx, 0)).g;
        float v10 = fbTex.Load(int3(int2(nextIdx.x, baseIdx.y), 0)).g;
        float v01 = fbTex.Load(int3(int2(baseIdx.x, nextIdx.y), 0)).g;
        float v11 = fbTex.Load(int3(nextIdx, 0)).g;

        float2 smoothWeights = smoothstep(float2(0.0, 0.0), float2(1.0, 1.0), weights);
        float v0 = lerp(v00, v10, smoothWeights.x);
        float v1 = lerp(v01, v11, smoothWeights.x);
        intensity = clamp(lerp(v0, v1, smoothWeights.y), 0.0, 1.0);
    }
    else if (sm == 3)
    {
        // catmull-rom 3x3 (9 taps)
        uint tw, th;
        fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = res / texSize;
        float2 uv = (pos - scaling * 0.5) / res;
        float4 sample = nm_rd_catmullRom3x3(fbTex, sampler_fbTex, uv, texelSize);
        intensity = clamp(sample.g, 0.0, 1.0);
    }
    else if (sm == 4)
    {
        // catmull-rom 4x4 (16 taps)
        uint tw, th;
        fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = res / texSize;
        float2 uv = (pos - scaling * 0.5) / res;
        float4 sample = nm_rd_catmullRom4x4(fbTex, sampler_fbTex, uv, texelSize);
        intensity = clamp(sample.g, 0.0, 1.0);
    }
    else if (sm == 5)
    {
        // b-spline 3x3 (9 taps)
        uint tw, th;
        fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = res / texSize;
        float2 uv = (pos - scaling * 0.5) / res;
        float4 sample = nm_rd_quadratic(fbTex, sampler_fbTex, uv, texelSize);
        intensity = clamp(sample.g, 0.0, 1.0);
    }
    else if (sm == 6)
    {
        // b-spline 4x4 (16 taps)
        uint tw, th;
        fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelSize = 1.0 / texSize;
        float2 scaling = res / texSize;
        float2 uv = (pos - scaling * 0.5) / res;
        float4 sample = nm_rd_bicubic(fbTex, sampler_fbTex, uv, texelSize);
        intensity = clamp(sample.g, 0.0, 1.0);
    }
    else
    {
        // smoothing == 1 (linear) or fallthrough (cosineMix)
        uint tw, th;
        fbTex.GetDimensions(tw, th);
        float2 texSize = float2((float)tw, (float)th);
        float2 texelPos = (pos * texSize / res) - float2(0.5, 0.5);
        float2 base = floor(texelPos);
        float2 weights = frac(texelPos);
        float2 nxt = base + float2(1.0, 1.0);

        int2 texSizeI = int2((int)tw, (int)th);
        int2 minIdx = int2(0, 0);
        int2 maxIdx = texSizeI - int2(1, 1);
        int2 baseI = clamp((int2)base, minIdx, maxIdx);
        int2 nextI = clamp((int2)nxt, minIdx, maxIdx);

        float v00 = fbTex.Load(int3(baseI, 0)).g;
        float v10 = fbTex.Load(int3(int2(nextI.x, baseI.y), 0)).g;
        float v01 = fbTex.Load(int3(int2(baseI.x, nextI.y), 0)).g;
        float v11 = fbTex.Load(int3(nextI, 0)).g;

        if (sm == 1)
        {
            float v0 = lerp(v00, v10, weights.x);
            float v1 = lerp(v01, v11, weights.x);
            intensity = clamp(lerp(v0, v1, weights.y), 0.0, 1.0);
        }
        else
        {
            float v0 = nm_rd_cosineMix(v00, v10, weights.x);
            float v1 = nm_rd_cosineMix(v01, v11, weights.x);
            intensity = clamp(nm_rd_cosineMix(v0, v1, weights.y), 0.0, 1.0);
        }
    }

    float3 rdColor = float3(intensity, intensity, intensity);

    if (inputIntens > 0.0)
    {
        float2 inputUv = pos / res;
        float3 inputColor = inputTex.SampleLevel(sampler_inputTex, inputUv, 0.0).rgb;
        rdColor = lerp(rdColor, inputColor, inputIntens);
    }

    return float4(rdColor, 1.0);
}

#endif // NM_EFFECT_REACTIONDIFFUSION_INCLUDED
