#ifndef NM_EFFECT_POINTSRENDER_INCLUDED
#define NM_EFFECT_POINTSRENDER_INCLUDED

// =============================================================================
// PointsRender.hlsl — render/pointsRender (func: "pointsRender")
//
// Blend agent trails with input for particle systems. Ported PIXEL-IDENTICALLY
// from the canonical WGSL sources (top-left origin, no per-effect Y flip;
// golden rule #1):
//   wgsl/diffuse.wgsl  progName "diffuse"  (frag_diffuse)        fullscreen
//   wgsl/copy.wgsl     progName "copy"     (frag_copy)           fullscreen
//   wgsl/deposit.wgsl  progName "deposit"  (vert/frag_deposit)   POINTS scatter
//   wgsl/blend.wgsl    progName "blend"    (frag_blend)          fullscreen
//
// PASS ORDER per frame (4) — from definition.js passes[]:
//   1. diffuse (program "diffuse", fullscreen) — decay the existing trail
//                                                (trail *= clamp(intensity/100)).
//   2. copy    (program "copy",    fullscreen) — blit decayed trail to the write
//                                                buffer before deposit (ping-pong
//                                                correction so HW blending is right).
//   3. deposit (program "deposit", POINTS scatter, Blend One One) — scatter agent
//                                                colors to the trail; one 1px point
//                                                per alive, density-passing agent.
//   4. blend   (program "blend",   fullscreen) — composite trail with input.
//
// PERSISTENT STATE TEXTURES (runtime double-buffers / persists per ref 04 §10.7):
//   global_points_trail (rgba16f, 100%) — the visual trail accumulation surface.
//     Decayed by diffuse, copied by copy, additively deposited into by deposit
//     (Blend One One), then composited by blend. Reads its own prior 'global_'
//     output so it persists frame-to-frame (runtime ping-pongs; §10.2/§10.7).
//     NOTE: matched by isStateSurface (suffix '_trail') → end-of-frame bindings
//     persist with NO swap.
//   global_xyz  (rgba32f) — agent state [x, y, z/heading, alive]. Produced upstream
//     by pointsEmit (sized stateSize x stateSize). Read by the deposit VERTEX stage
//     (pos.xyz for placement, pos.w >= 0.5 = alive cull). READ-ONLY here.
//   global_rgba (rgba32f) — agent color [r, g, b, a]. Read by the deposit VERTEX
//     stage. READ-ONLY here.
//
// NOTE: multi-pass / agent-consumer effect with a POINTS scatter → ships as a
// runtime-rendered Texture2D. NO Shader Graph Custom Function wrapper is provided
// (3D/multi-pass/geometry per PORTING-GUIDE §"Per-effect output checklist"). The
// C# runtime drives the 4 passes in order, rebinding global_points_trail read/write
// targets per pass and issuing DrawProcedural(Points, stateSize*stateSize) for the
// deposit scatter (count='input' = xyzTex dims squared).
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(t, coord, 0) → t.Load(int3(coord, 0)) — integer texel fetch,
//    point, no filtering. The deposit VERTEX stage reads agent state (rgba32f) this
//    way (SM4.5 permits VS texture Load).
//  * WGSL textureSample(t, s, uv) → t.Sample(sampler_t, uv) — linear, clamp-to-edge,
//    non-sRGB. diffuse/copy/blend sample by UV.
//  * fragCoord = @builtin(position).xy (top-left, +0.5 centered) → NM_FragCoord(i).
//    diffuse derives uv = fragCoord / u.resolution (the resolution UNIFORM ==
//    render-target size). copy derives uv = pos.xy / textureDimensions(sourceTex)
//    (the BOUND texture's own dims). blend derives uv = pos.xy / max(resolution, 1).
//    Each reproduced literally.
//  * fract→frac, mix→lerp, clamp/cos/sin map 1:1. nm_mod / fmod NOT used here.
//    The deposit VS uses integer % (x = id % stateSize, y = id / stateSize) on
//    non-negative ids — trunc semantics match WGSL %.
//  * No NMCore helpers used (no pcg/prng/random/nm_mod). Density cull uses the
//    full-precision golden-ratio literal 0.618033988749895 verbatim.
//  * D3D points are 1px, matching the reference gl_PointSize=1 / WGSL implicit 1px
//    deposit. No Y flip (golden rule #1): clipPos = pos.xy*2-1 (viewMode 0) or the
//    rotated/projected p.xy (viewMode 1) is used directly as clip-space x/y.
//  * is2DSystem detection, the X/Y/Z rotation matrices (literal arg order), the
//    post-rotation pan (p.x+=posX, p.y+=posY), and the ortho scale branch
//    (2D: p.xy*3.5*viewScale ; 3D: p.xy/40*viewScale) are copied verbatim.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Textures (runtime rebinds per pass per definition.js inputs{}) ---------
// diffuse: trailTex (Sample)
// copy:    sourceTex (Sample)  -- bound to global_points_trail
// deposit: xyzTex, rgbaTex (Load, in VERTEX stage)
// blend:   inputTex (Sample), trailTex (Sample)
Texture2D xyzTex;       SamplerState sampler_xyzTex;
Texture2D rgbaTex;      SamplerState sampler_rgbaTex;
Texture2D trailTex;     SamplerState sampler_trailTex;
Texture2D sourceTex;    SamplerState sampler_sourceTex;
Texture2D inputTex;     SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
float density;          // globals.density        default 50
float intensity;        // globals.intensity      default 75  (trail persistence)
float inputIntensity;   // globals.inputIntensity default 10.15
int   viewMode;         // globals.viewMode       default 0   (0=flat, 1=ortho)
float rotateX;          // globals.rotateX        default 0.3
float rotateY;          // globals.rotateY        default 0
float rotateZ;          // globals.rotateZ        default 0
float viewScale;        // globals.viewScale      default 0.8
float posX;             // globals.posX           default 0
float posY;             // globals.posY           default 0
float matteOpacity;     // globals.matteOpacity   default 1.0

// =============================================================================
// PASS 1: diffuse — decay existing trail (frag_diffuse, fullscreen).
//   WGSL: uv = fragCoord / u.resolution; decay = clamp(intensity/100, 0, 1);
//         return trailColor * decay.
// =============================================================================
float4 frag_diffuse(NMVaryings i) : SV_Target
{
    float2 uv = NM_FragCoord(i) / resolution;

    // Sample the trail texture directly (no blur).
    float4 trailColor = trailTex.Sample(sampler_trailTex, uv);

    // Apply intensity decay (persistence). intensity=100 → no decay, 0 → instant fade.
    // Clamp to [0,1] each frame to bound unbounded HDR accumulation via additive
    // deposit blending (reference a0d8ea14).
    float decay = clamp(intensity / 100.0, 0.0, 1.0);
    return clamp(trailColor * decay, 0.0, 1.0);
}

// =============================================================================
// PASS 2: copy — blit source to destination for ping-pong correction
//   (frag_copy, fullscreen). WGSL derives uv from the BOUND texture's own dims.
//   uv = position.xy / textureDimensions(sourceTex, 0).
// =============================================================================
float4 frag_copy(NMVaryings i) : SV_Target
{
    uint dw, dh;
    sourceTex.GetDimensions(dw, dh);
    float2 uv = NM_FragCoord(i) / float2((float)dw, (float)dh);
    return sourceTex.Sample(sampler_sourceTex, uv);
}

// =============================================================================
// PASS 3: deposit — POINTS scatter (Blend One One additive).
//
// Custom vertex stage: one point per agent (count = stateSize*stateSize). The
// runtime issues DrawProcedural(Points, count). Reads agent state in the VERTEX
// stage via Texture2D.Load (SM4.5 permits VS texture Load). D3D points are 1px,
// matching the reference gl_PointSize=1 / WGSL implicit 1px deposit.
//
// Ported verbatim from deposit.wgsl (and deposit.vert): the 2D/3D view transform,
// density culling, is2DSystem detection, XYZ rotation, pan, and ortho scale.
// Off-screen cull writes clip position (2,2,0,1). No Y flip (golden rule #1).
// =============================================================================
struct PRDepositVaryings
{
    float4 positionCS : SV_POSITION;
    float  pointSize  : PSIZE;      // D3D point topology requires a PSIZE output;
                                    // 1px deposit (reference gl_PointSize = 1.0).
    float4 color      : TEXCOORD0;
};

PRDepositVaryings vert_deposit(uint vertexID : SV_VertexID)
{
    PRDepositVaryings o;
    o.pointSize = 1.0;   // all paths: 1px point (culled points are sent off-screen).

    // State size from xyz texture dimensions (inherited from pointsEmit).
    uint tw, th;
    xyzTex.GetDimensions(tw, th);
    int stateSize = (int)tw;
    int totalAgents = stateSize * stateSize;

    // Cull vertices beyond texture size.
    if ((int)vertexID >= totalAgents)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color = float4(0.0, 0.0, 0.0, 0.0);
        return o;
    }

    // Density-based culling.  WGSL: fract(f32(vertexIndex) * 0.618033988749895).
    float cullThreshold = density / 100.0;
    float particleRandom = frac((float)vertexID * 0.618033988749895);
    if (particleRandom > cullThreshold)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color = float4(0.0, 0.0, 0.0, 0.0);
        return o;
    }

    // Texel for this agent.  WGSL: x = id % stateSize, y = id / stateSize.
    int x = (int)vertexID % stateSize;
    int y = (int)vertexID / stateSize;

    // Read agent position and color (VS Load, SM4.5).
    float4 pos = xyzTex.Load(int3(int2(x, y), 0));
    float4 col = rgbaTex.Load(int3(int2(x, y), 0));

    // Cull dead agents (pos.w >= 0.5 means alive).
    if (pos.w < 0.5)
    {
        o.positionCS = float4(2.0, 2.0, 0.0, 1.0);
        o.color = float4(0.0, 0.0, 0.0, 0.0);
        return o;
    }

    float2 clipPos;

    if (viewMode == 0)
    {
        // 2D mode: positions are normalized 0..1.
        clipPos = pos.xy * 2.0 - 1.0;
    }
    else
    {
        // 3D mode: apply rotation and orthographic projection.
        float3 p = pos.xyz;

        // Detect 2D system (coords in 0-1, Z near 0) vs 3D attractor (coords ±40).
        bool is2DSystem = abs(p.z) < 1.0 && p.x >= 0.0 && p.x <= 1.0 && p.y >= 0.0 && p.y <= 1.0;

        if (is2DSystem)
        {
            // Center 2D coords around origin: 0-1 -> -0.5 to 0.5.
            p = float3(p.x - 0.5, p.y - 0.5, 0.0);
        }

        // Apply rotation around X axis.
        float cosX = cos(rotateX);
        float sinX = sin(rotateX);
        p = float3(p.x, p.y * cosX - p.z * sinX, p.y * sinX + p.z * cosX);

        // Apply rotation around Y axis.
        float cosY = cos(rotateY);
        float sinY = sin(rotateY);
        p = float3(p.x * cosY + p.z * sinY, p.y, -p.x * sinY + p.z * cosY);

        // Apply rotation around Z axis.
        float cosZ = cos(rotateZ);
        float sinZ = sin(rotateZ);
        p = float3(p.x * cosZ - p.y * sinZ, p.x * sinZ + p.y * cosZ, p.z);

        // Apply X/Y offset after rotation (pan in screen space).
        p.x = p.x + posX;
        p.y = p.y + posY;

        // Orthographic projection with scale.
        if (is2DSystem)
        {
            // 2D systems: coords are ±0.5, scale to fill viewport (3.5x close-up).
            clipPos = p.xy * 3.5 * viewScale;
        }
        else
        {
            // 3D attractors: coords range roughly ±40, normalize then scale.
            clipPos = p.xy / 40.0 * viewScale;
        }
    }

    // Y-orientation parity (CRITICAL): every FULLSCREEN pass (NMVertFullscreen)
    // counter-flips clip.y by _ProjectionParams.x so that, when rendering INTO a
    // RenderTexture on Metal/D3D (_ProjectionParams.x == -1), all passes store the
    // trail in ONE consistent orientation. The deposit uses a CUSTOM vertex stage,
    // so it MUST apply the SAME counter-flip — otherwise the scattered points land
    // vertically MIRRORED relative to where the diffuse/copy/blend fullscreen passes
    // read+write the same trail, and the composited output is upside-down vs the
    // GLSL golden (which keeps GL bottom-left consistent throughout).
    o.positionCS = float4(clipPos.x, clipPos.y * _ProjectionParams.x, 0.0, 1.0);
    o.color = float4(col.rgb, col.a);
    return o;
}

float4 frag_deposit(PRDepositVaryings i) : SV_Target
{
    return i.color;
}

// =============================================================================
// PASS 4: blend — composite accumulated trail with input (frag_blend, fullscreen).
//   WGSL: size = max(resolution, vec2(1)); uv = position.xy / size;
//         t = inputIntensity/100; matteAlpha = matteOpacity;
//         trailPresence = max(max(r,g),b);
//         rgb   = trailColor.rgb + inputColor.rgb * t * matteAlpha;
//         alpha = max(trailPresence, matteAlpha).
// =============================================================================
float4 frag_blend(NMVaryings i) : SV_Target
{
    float2 size = max(resolution, float2(1.0, 1.0));
    float2 uv = NM_FragCoord(i) / size;

    float4 inputColor = inputTex.Sample(sampler_inputTex, uv);
    float4 trailColor = trailTex.Sample(sampler_trailTex, uv);

    // Additive blend: trail + scaled input. inputIntensity 0 = black, 100 = full input.
    float t = inputIntensity / 100.0;
    float matteAlpha = matteOpacity;

    // Trail presence based on max RGB channel.
    float trailPresence = max(max(trailColor.r, trailColor.g), trailColor.b);

    // Background contribution scaled by matte opacity (premultiplied); trail is NOT.
    float3 rgb = trailColor.rgb + inputColor.rgb * t * matteAlpha;

    // Alpha: where trail exists, full opacity; elsewhere, matte opacity.
    float alpha = max(trailPresence, matteAlpha);

    // Clamp to [0,1]: deposit can push trail alpha > 1 within a frame; an alpha > 1
    // written here drives a negative GL_ONE_MINUS_SRC_ALPHA factor downstream (black
    // dots in dense regions). Reference 77e45a5e.
    return clamp(float4(rgb, alpha), 0.0, 1.0);
}

#endif // NM_EFFECT_POINTSRENDER_INCLUDED
