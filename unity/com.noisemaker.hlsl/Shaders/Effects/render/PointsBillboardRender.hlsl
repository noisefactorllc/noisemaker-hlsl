#ifndef NM_EFFECT_POINTSBILLBOARDRENDER_INCLUDED
#define NM_EFFECT_POINTSBILLBOARDRENDER_INCLUDED

// =============================================================================
// PointsBillboardRender.hlsl — render/pointsBillboardRender
//   (func: "pointsBillboardRender") — draw particle agents as camera-facing
//   billboard sprite quads (SDF shapes or a sprite texture).
//
// AGENT VISUALIZER / multi-pass FEEDBACK effect (3D/RENDER tier). Ported
// PIXEL-IDENTICALLY from the canonical WGSL sources (top-left origin, no
// per-effect Y flip; golden rule #1):
//   wgsl/diffuse.wgsl   progName "diffuse"   (frag_diffuse)          fullscreen
//   wgsl/copy.wgsl      progName "copy"      (frag_copy)             fullscreen
//   wgsl/deposit.wgsl   progName "deposit"   (vert/frag_deposit)     BILLBOARD scatter
//   wgsl/blend.wgsl     progName "blend"     (frag_blend)            fullscreen
//
// PASS ORDER per frame (4) — from definition.js passes[]:
//   1. diffuse  (program "diffuse",  fullscreen)            decay the trail
//                                                           (persistence = intensity)
//   2. copy     (program "copy",     fullscreen)            blit decayed trail to the
//                                                           write buffer before deposit
//   3. deposit  (program "deposit",  BILLBOARDS scatter)    Blend One One — additive
//                                                           scatter of agent billboards
//   4. blend    (program "blend",    fullscreen)            alpha-composite trail over
//                                                           the scaled pipeline input
//
// SURFACES:
//   global_xyz  (rgba32f) — [x, y, z, alive] agent positions. Produced upstream
//       by pointsEmit (sized stateSize x stateSize); consumed (Load) by the deposit
//       VERTEX stage. NOT written here (read-only). isStateSurface (suffix '_xyz').
//   global_rgba (rgba32f) — [r, g, b, a] agent color (from pointsEmit). Read (Load)
//       by the deposit VERTEX stage. isStateSurface (suffix '_rgba'). read-only.
//   global_billboard_trail (rgba16f, 100%) — PERSISTENT private accumulation trail:
//       decayed by diffuse, copied by copy, additively deposited into by deposit
//       (Blend One One), composited with input by blend. Reads its own prior
//       'global_' output so it persists frame-to-frame (runtime double-buffers /
//       ping-pongs; reference 04 §10.2/§10.7). NOT an isStateSurface (no
//       _xyz/_vel/_rgba suffix, no 'state').
//
// NOTE: multi-pass / agent-visualizer effect → ships as a runtime-rendered
// Texture2D. NO Shader Graph Custom Function wrapper (3D / multi-pass / geometry
// per PORTING-GUIDE). The C# runtime drives the 4 passes in order, rebinding
// read/write targets per pass and issuing DrawProcedural(Triangles, count*6) for
// the deposit billboard scatter (count = stateSize*stateSize from xyzTex dims;
// 6 verts = 2 triangles per quad).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) — integer texel fetch,
//    point, no filtering. Agent state (xyz/rgba) is read this way in the VERTEX
//    stage (SM4.5 permits VS texture Load). rgba32f.
//  * WGSL textureSample(t, s, uv) → t.Sample(sampler_t, uv) — linear, clamp,
//    non-sRGB. Used by diffuse/copy/blend (UV blit) and the deposit sprite sample.
//  * fragCoord = @builtin(position).xy (top-left, +0.5 centered) → NM_FragCoord(i).
//    diffuse/copy/blend derive uv = fragCoord / u.resolution (the resolution
//    UNIFORM == render-target size). Reproduced literally.
//  * fract→frac, mix→lerp, clamp/cos/sin/length/dot/smoothstep/exp/sign map 1:1.
//    nm_mod / fmod NOT used. Integer particle id math uses HLSL int '%' and '/'
//    (truncation toward 0), matching WGSL i32 %  / on non-negative ids exactly.
//  * hash() is this effect's OWN sin-hash (NOT NMCore) — ported verbatim. WGSL
//    casts u.seed (i32) → f32 explicitly; we keep seed as a float uniform and add
//    it directly (the runtime injects the integer value as a float; identical).
//  * Quad clip transform & per-particle size/rotation reproduced exactly from
//    deposit.wgsl (top-left clip, no Y flip; off-screen cull writes (2,2,0,1)).
//  * The 2D/3D viewMode branch (rotateX/Y/Z, is2DSystem detection, ortho scale)
//    is reproduced literally from deposit.wgsl.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Textures (runtime rebinds per pass per definition.js inputs{}) ---------
// diffuse: trailTex (Sample)
// copy:    sourceTex (Sample)  -- bound to global_billboard_trail
// deposit: xyzTex,rgbaTex (Load, in VERTEX stage); spriteTex (Sample, in FRAGMENT)
// blend:   inputTex,trailTex (Sample)
Texture2D xyzTex;     SamplerState sampler_xyzTex;
Texture2D rgbaTex;    SamplerState sampler_rgbaTex;
Texture2D spriteTex;  SamplerState sampler_spriteTex;
Texture2D trailTex;   SamplerState sampler_trailTex;
Texture2D sourceTex;  SamplerState sampler_sourceTex;
Texture2D inputTex;   SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int   shapeMode;        // globals.shapeMode      default 1 (circle)
float depositOpacity;   // globals.depositOpacity default 20
float density;          // globals.density        default 50
float pointSize;        // globals.pointSize      default 8
float sizeVariation;    // globals.sizeVariation  default 0
float rotationVar;      // globals.rotationVar    default 0 (alias rotationVariation)
float seed;             // globals.seed           default 42 (typed int; injected as float)
int   viewMode;         // globals.viewMode       default 0 (flat)
float rotateX;          // globals.rotateX        default 0.3
float rotateY;          // globals.rotateY        default 0
float rotateZ;          // globals.rotateZ        default 0
float viewScale;        // globals.viewScale      default 0.8
float posX;             // globals.posX           default 0
float posY;             // globals.posY           default 0
float intensity;        // globals.intensity      default 75
float inputIntensity;   // globals.inputIntensity default 10.15

// =============================================================================
// PASS 1: diffuse — decay the existing trail (frag_diffuse, fullscreen).
//   WGSL: decay = clamp(intensity/100, 0, 1); return trailColor * decay.
// =============================================================================
float4 frag_diffuse(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;

    // Sample the trail texture directly (no blur).
    float4 trailColor = trailTex.Sample(sampler_trailTex, uv);

    // Apply intensity decay (persistence). intensity=100 → no decay, 0 → instant fade.
    float decay = clamp(intensity / 100.0, 0.0, 1.0);
    return trailColor * decay;
}

// =============================================================================
// PASS 2: copy — blit source to destination (frag_copy, fullscreen).
//   WGSL: uv = position.xy / resolution; return textureSample(sourceTex, s, uv).
// =============================================================================
float4 frag_copy(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;
    return sourceTex.Sample(sampler_sourceTex, uv);
}

// =============================================================================
// PASS 3: deposit — BILLBOARD scatter (Blend One One additive).
//
// Custom vertex stage: 6 vertices (two triangles) per agent. count =
// stateSize*stateSize so the runtime issues DrawProcedural(Triangles, count*6).
// Reads agent state in the VERTEX stage via Texture2D.Load (SM4.5). Emits a
// camera-facing quad with per-particle size/rotation variation and a sprite UV
// varying consumed by the fragment SDF/texture stage.
//
// Ported verbatim from deposit.wgsl (vertexMain/fragmentMain).
// =============================================================================
struct PBRDepositVaryings
{
    float4 positionCS : SV_POSITION;
    float4 color      : TEXCOORD0;
    float2 spriteUV   : TEXCOORD1;
};

// Deterministic noise function for per-particle variation (this effect's OWN).
// WGSL: fract(sin(n + f32(u.seed)) * 43758.5453123).
float pbr_hash(float n)
{
    return frac(sin(n + seed) * 43758.5453123);
}

PBRDepositVaryings vert_deposit(uint vertexID : SV_VertexID)
{
    PBRDepositVaryings o;

    // Each quad uses 6 vertices (2 triangles).
    int particleID    = (int)vertexID / 6;
    int vertexInQuad  = (int)vertexID % 6;

    // State size from xyz texture dimensions (inherited from pointsEmit).
    uint tw, th;
    xyzTex.GetDimensions(tw, th);
    int stateSize   = (int)tw;
    int totalAgents = stateSize * stateSize;

    // Cull particles beyond texture size.
    if (particleID >= totalAgents)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color      = float4(0.0, 0.0, 0.0, 0.0);
        o.spriteUV   = float2(0.0, 0.0);
        return o;
    }

    // Density-based culling.
    float cullThreshold  = density / 100.0;
    float particleRandom = frac((float)particleID * 0.618033988749895);
    if (particleRandom > cullThreshold)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color      = float4(0.0, 0.0, 0.0, 0.0);
        o.spriteUV   = float2(0.0, 0.0);
        return o;
    }

    // Texel for this particle.  WGSL: x = id % stateSize, y = id / stateSize.
    int x = particleID % stateSize;
    int y = particleID / stateSize;

    // Read particle position and color (VS Load, SM4.5, rgba32f).
    float4 pos = xyzTex.Load(int3(int2(x, y), 0));
    float4 col = rgbaTex.Load(int3(int2(x, y), 0));

    // Cull dead agents (pos.w >= 0.5 means alive).
    if (pos.w < 0.5)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color      = float4(0.0, 0.0, 0.0, 0.0);
        o.spriteUV   = float2(0.0, 0.0);
        return o;
    }

    float2 clipPos;

    if (viewMode == 0)
    {
        // 2D mode: positions are normalized 0..1. No Y flip (golden rule #1).
        clipPos = pos.xy * 2.0 - 1.0;
    }
    else
    {
        // 3D mode: apply rotation and orthographic projection.
        float3 p = pos.xyz;

        // Detect a 2D system (coords in 0-1) vs a 3D attractor (coords ±40).
        bool is2DSystem = abs(p.z) < 1.0 && p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0;

        if (is2DSystem)
        {
            p = float3(p.x - 0.5, p.y - 0.5, 0.0);
        }

        // Rotation around X axis.
        float cosX = cos(rotateX);
        float sinX = sin(rotateX);
        p = float3(p.x, p.y * cosX - p.z * sinX, p.y * sinX + p.z * cosX);

        // Rotation around Y axis.
        float cosY = cos(rotateY);
        float sinY = sin(rotateY);
        p = float3(p.x * cosY + p.z * sinY, p.y, -p.x * sinY + p.z * cosY);

        // Rotation around Z axis.
        float cosZ = cos(rotateZ);
        float sinZ = sin(rotateZ);
        p = float3(p.x * cosZ - p.y * sinZ, p.x * sinZ + p.y * cosZ, p.z);

        // Apply X/Y offset after rotation.
        p.x = p.x + posX;
        p.y = p.y + posY;

        // Orthographic projection with scale.
        if (is2DSystem)
        {
            clipPos = p.xy * 3.5 * viewScale;
        }
        else
        {
            clipPos = p.xy / 40.0 * viewScale;
        }
    }

    // Per-particle size variation (seeded deterministic).
    float sizeNoise      = pbr_hash((float)particleID);
    float sizeMultiplier = 1.0 - (sizeVariation / 100.0) * (sizeNoise - 0.5);
    float finalSize      = pointSize * sizeMultiplier;

    // Per-particle rotation (seeded deterministic).
    float rotationNoise = pbr_hash((float)particleID + 1234.5);
    float rotation      = (rotationVar / 100.0) * rotationNoise * 6.283185; // 0..2pi

    // Convert pixel size to clip-space units. resolution == render-target size.
    float2 pixelToClip = 2.0 / resolution;
    float  halfSize    = finalSize * 0.5;
    float2 sizeClip    = halfSize * pixelToClip;

    // Quad vertex offsets (two triangles: 0-1-2, 2-1-3).
    float2 offsets[6];
    offsets[0] = float2(-1.0, -1.0); // bottom-left
    offsets[1] = float2( 1.0, -1.0); // bottom-right
    offsets[2] = float2(-1.0,  1.0); // top-left
    offsets[3] = float2(-1.0,  1.0); // top-left
    offsets[4] = float2( 1.0, -1.0); // bottom-right
    offsets[5] = float2( 1.0,  1.0); // top-right

    float2 offset = offsets[vertexInQuad];

    // Apply rotation to offset.
    float cosR = cos(rotation);
    float sinR = sin(rotation);
    float2 rotatedOffset = float2(
        offset.x * cosR - offset.y * sinR,
        offset.x * sinR + offset.y * cosR
    );

    // Scale offset and add to center position.
    float2 finalPos = clipPos + rotatedOffset * sizeClip;

    o.positionCS = float4(finalPos, 0.0, 1.0);
    o.color      = float4(col.rgb, col.a);

    // Sprite UV coordinates (0..1 range).
    o.spriteUV = offset * 0.5 + 0.5;

    return o;
}

float4 frag_deposit(PBRDepositVaryings i) : SV_Target
{
    float opacity = depositOpacity / 100.0;

    if (shapeMode == 0)
    {
        // Texture mode: sample sprite texture.
        float4 spriteColor = spriteTex.Sample(sampler_spriteTex, i.spriteUV);
        return float4(spriteColor.rgb * i.color.rgb, spriteColor.a * i.color.a) * opacity;
    }

    // Procedural SDF shapes.
    float2 p = i.spriteUV - 0.5;
    float sdf;
    float alpha;

    if (shapeMode == 1)
    {
        // Circle.
        sdf = length(p) - 0.45;
    }
    else if (shapeMode == 2)
    {
        // Ring.
        sdf = abs(length(p) - 0.35) - 0.08;
    }
    else if (shapeMode == 3)
    {
        // Square.
        sdf = max(abs(p.x), abs(p.y)) - 0.4;
    }
    else if (shapeMode == 4)
    {
        // Diamond.
        sdf = abs(p.x) + abs(p.y) - 0.45;
    }
    else if (shapeMode == 5)
    {
        // Equilateral triangle (Inigo Quilez SDF).
        float r = 0.25;
        float k = 1.732050808; // sqrt(3)
        float2 t = float2(abs(p.x) - r, p.y - 0.04 + r / k);
        if (t.x + k * t.y > 0.0) { t = float2(t.x - k * t.y, -k * t.x - t.y) / 2.0; }
        t.x -= clamp(t.x, -2.0 * r, 0.0);
        sdf = -length(t) * sign(t.y);
    }
    else if (shapeMode == 6)
    {
        // 5-point star (Inigo Quilez SDF — straight edges).
        float r = 0.35;
        float rf = 0.4;
        float2 k1 = float2(0.809016994375, -0.587785252292);
        float2 k2 = float2(-k1.x, k1.y);
        float2 s = float2(abs(p.x), p.y);
        s -= 2.0 * max(dot(k1, s), 0.0) * k1;
        s -= 2.0 * max(dot(k2, s), 0.0) * k2;
        s.x = abs(s.x);
        s.y -= r;
        float2 ba = rf * float2(-k1.y, k1.x) - float2(0.0, 1.0);
        float h = clamp(dot(s, ba) / dot(ba, ba), 0.0, r);
        sdf = length(s - ba * h) * sign(s.y * ba.x - s.x * ba.y);
    }
    else
    {
        // Soft (7) — gaussian falloff.
        alpha = exp(-dot(p, p) * 8.0);
        return float4(i.color.rgb * alpha, alpha * i.color.a) * opacity;
    }

    alpha = 1.0 - smoothstep(-0.02, 0.02, sdf);
    return float4(i.color.rgb * alpha, alpha * i.color.a) * opacity;
}

// =============================================================================
// PASS 4: blend — composite trail over scaled input (frag_blend, fullscreen).
//   WGSL: t = inputIntensity/100; scaledInput = inputColor * t; alpha-composite
//   trail over scaledInput. size = max(resolution, vec2(1.0)).
// =============================================================================
float4 frag_blend(NMVaryings i) : SV_Target
{
    float2 size = max(resolution, float2(1.0, 1.0));
    float2 uv = NM_FragCoord(i) / size;

    float4 inputColor = inputTex.Sample(sampler_inputTex, uv);
    float4 trailColor = trailTex.Sample(sampler_trailTex, uv);

    // Blend: trail over scaled input using alpha.
    // inputIntensity 0 = trail only, 100 = trail over full input.
    float t = inputIntensity / 100.0;
    float4 scaledInput = inputColor * t;

    // Alpha compositing: trail over input.
    float outAlpha = trailColor.a + scaledInput.a * (1.0 - trailColor.a);
    float3 outRGB;
    if (outAlpha > 0.0)
    {
        outRGB = (trailColor.rgb * trailColor.a + scaledInput.rgb * scaledInput.a * (1.0 - trailColor.a)) / outAlpha;
    }
    else
    {
        outRGB = float3(0.0, 0.0, 0.0);
    }

    return float4(outRGB, outAlpha);
}

#endif // NM_EFFECT_POINTSBILLBOARDRENDER_INCLUDED
