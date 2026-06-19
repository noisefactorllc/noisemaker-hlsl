#ifndef NM_FULLSCREEN_INCLUDED
#define NM_FULLSCREEN_INCLUDED

// =============================================================================
// NMFullscreen.hlsl — fullscreen-triangle vertex stage, engine-provided
// uniforms, and coordinate helpers shared by every render-type effect pass.
//
// The runtime drives passes with DrawProcedural(Triangles, 3), mirroring the
// reference FULLSCREEN_TRIANGLE (3 verts, NDC -1..3). UVs are generated here so
// the coordinate orientation is controlled in ONE place (see NMCore NM_FLIP_Y).
//
// UNIFORM MODEL: we bind per-effect parameters as INDIVIDUAL NAMED uniforms
// (mirroring the GLSL backend), NOT the WGSL packed `array<vec4,N> data[]`.
// Values are identical (reference spec 07 §3 confirms parity); named uniforms
// are Unity-idiomatic and map 1:1 to Shader Graph Custom Function inputs.
// The runtime sets them via MaterialPropertyBlock by their reference `uniform`
// name. Engine-provided globals are prefixed `_NM_` and #define-aliased to the
// reference names so ported shader bodies stay close to the WGSL/GLSL source.
// =============================================================================

#include "NMCore.hlsl"

// ---- Engine-provided per-frame globals (set by NMPipeline each frame) -------
float4 _NM_Resolution;      // .xy = current render target size (px)
float4 _NM_FullResolution;  // .xy = full (untiled) size; denominator for `st`
float4 _NM_TileOffset;      // .xy = tiled-render pixel offset (0,0 untiled)
float  _NM_Time;            // normalized 0..1 animation time
float  _NM_DeltaTime;       // normalized delta
float  _NM_RenderScale;     // 1.0 untiled
float  _NM_AspectRatio;     // fullResolution.x / fullResolution.y
int    _NM_Frame;           // integer frame index

// Reference-name aliases so ported bodies can use bare `resolution`, `time`...
#define resolution      (_NM_Resolution.xy)
#define fullResolution  (_NM_FullResolution.xy)
#define tileOffset      (_NM_TileOffset.xy)
#define time            (_NM_Time)
#define deltaTime       (_NM_DeltaTime)
#define renderScale     (_NM_RenderScale)
#define aspectRatio     (_NM_FullResolution.x / _NM_FullResolution.y)

struct NMVaryings
{
    float4 positionCS : SV_POSITION;
    float2 uv         : TEXCOORD0;   // (0,0)=canonical origin (top-left, WGSL)
};

// Unity built-in: _ProjectionParams.x = -1 when the active render target's Y is
// flipped (i.e. rendering INTO a RenderTexture on Metal/D3D). Each DrawProcedural
// into an RT would otherwise flip Y once, so textures of odd-vs-even render depth end
// up in OPPOSITE orientations — invisible for single-input chains (consistent parity
// to present) but exposed when a mixer samples two differently-rendered inputs
// together (blendMode: inputTex was 1 render, tex/o0 was 2). Counter-flipping clip.y
// by _ProjectionParams.x makes EVERY pass store the SAME orientation regardless of
// render depth, so all downstream sampling is consistent.
float4 _ProjectionParams;

// Fullscreen triangle from SV_VertexID. Matches reference positions:
//   id 0 -> uv(0,0) clip(-1,-1)   id 1 -> uv(2,0) clip(3,-1)   id 2 -> uv(0,2) clip(-1,3)
// uv == reference `pos*0.5+0.5`.
NMVaryings NMVertFullscreen(uint vertexID : SV_VertexID)
{
    float2 uv   = float2((vertexID << 1) & 2, vertexID & 2);  // (0,0),(2,0),(0,2)
    float2 clip = uv * 2.0 - 1.0;                             // (-1,-1),(3,-1),(-1,3)

    NMVaryings o;
    o.positionCS = float4(clip.x, clip.y * _ProjectionParams.x, 0.0, 1.0);
#if NM_FLIP_Y
    o.uv = float2(uv.x, 1.0 - uv.y);
#else
    o.uv = uv;
#endif
    return o;
}

// gl_FragCoord / WGSL position.xy analog: pixel-centered (+0.5) target coords.
// uv*resolution at a pixel center = (px+0.5). Matches the reference exactly.
float2 NM_FragCoord(NMVaryings i)  { return i.uv * _NM_Resolution.xy; }

// globalCoord = fragCoord + tileOffset (the reference's per-tile shift).
float2 NM_GlobalCoord(NMVaryings i){ return NM_FragCoord(i) + _NM_TileOffset.xy; }

#endif // NM_FULLSCREEN_INCLUDED
