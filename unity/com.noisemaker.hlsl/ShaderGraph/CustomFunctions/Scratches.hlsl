#ifndef NM_SCRATCHES_SG_INCLUDED
#define NM_SCRATCHES_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Scratches.hlsl
//
// Shader Graph Custom Function wrapper for filter/scratches.
//
// IMPORTANT — PARTIAL SUPPORT ONLY:
//   The scratches effect requires a CPU-generated overlay texture (overlayTex)
//   produced by asyncInit / traceWorms (4 layers of worm-traced white scratch
//   lines). This texture is NOT procedurally generatable in a single Shader Graph
//   node — it must be baked at init time by C# and supplied as a Texture2D.
//
//   This wrapper exposes the GPU blend pass only. The caller must:
//     1. Run the C# asyncInit equivalent to produce OverlayTex.
//     2. Supply OverlayTex as a node input here.
//   Without a valid OverlayTex the output equals the input unchanged (overlay.a=0).
//
// Inputs:
//   InputTex   : main scene/effect input surface
//   OverlayTex : CPU-baked scratch mask (RGBA, white lines on transparent BG)
//   SS         : sampler state (unused by blend — both textures are .Load()ed)
//   UV         : 0..1 fragment UV (top-left origin, WGSL convention)
//   Resolution : render target pixel dimensions (to convert UV → integer coord)
//   Alpha      : scratch intensity [0,1], default 0.75
// =============================================================================

#include "../../Shaders/Effects/filter/Scratches.hlsl"

// InputTex   : main input surface
// OverlayTex : CPU-baked scratch mask
// SS         : sampler state (required by Shader Graph node type; unused internally)
// UV         : 0..1 fragment UV
// Resolution : pixel dimensions of the render target (float2)
// Alpha      : scratch intensity
void NM_Scratches_float(
    UnityTexture2D    InputTex,
    UnityTexture2D    OverlayTex,
    UnitySamplerState SS,
    float2            UV,
    float2            Resolution,
    float             Alpha,
    out float4        Out)
{
    // Override the uniform declared in Scratches.hlsl for this invocation.
    // (Shader Graph passes Alpha as a direct parameter.)
    alpha = Alpha;   // TODO(verify): check that writing the global here does not
                     // conflict with a MaterialPropertyBlock binding at the same time.

    // Convert normalised UV to integer pixel coord (mirrors WGSL i32(pos.x/y)).
    int2 coord = int2(UV * Resolution);

    float4 base    = InputTex.tex.Load(int3(coord, 0));
    float4 overlay = OverlayTex.tex.Load(int3(coord, 0));

    Out = nm_scratches_blend(base, overlay);
}

#endif // NM_SCRATCHES_SG_INCLUDED
