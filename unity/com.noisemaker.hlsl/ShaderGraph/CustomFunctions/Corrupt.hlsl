#ifndef NM_CORRUPT_SG_INCLUDED
#define NM_CORRUPT_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Corrupt.hlsl
//
// Shader Graph Custom Function wrapper for filter/corrupt (single render pass).
// Add a Custom Function node, point it at this file, select NM_Corrupt_float, and
// wire the named inputs + InputTex/SS/UV. Outputs RGBA.
//
// The core nm_corrupt(...) in Shaders/Effects/filter/Corrupt.hlsl reads its scalar
// parameters from module-scope named uniforms (intensity/bandHeight/sort/shift/
// channelShift/melt/scatter/bits/speed/seed) — matching the runtime's individual-
// named-uniform binding model. In a standalone Shader Graph node those globals are
// not bound by the runtime, so this wrapper assigns the node inputs to them before
// calling nm_corrupt, bridging the named inputs into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Intensity    : intensity    (0..100),  default 50
//   BandHeight   : bandHeight   (1..100),  default 10
//   Sort         : sort         (0..100),  default 50
//   Shift        : shift        (0..100),  default 50
//   ChannelShift : channelShift (0..100),  default 0
//   Melt         : melt         (0..100),  default 0
//   Scatter      : scatter      (0..100),  default 0
//   Bits         : bits         (0..100),  default 0
//   Speed        : speed        (int 0..5), default 1
//   Seed         : seed         (int 1..100), default 1
//   InputTex     : source surface to corrupt
//   SS           : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV           : 0..1 fragment UV (top-left origin, WGSL convention)
//
// NOTE: nm_corrupt derives fragCoord (pos.xy) from UV * input-tex size, since the
// WGSL computes uv = pos.xy / textureDimensions(inputTex). We pass the input tex
// dimensions to reconstruct pixel-centered fragCoord from the 0..1 UV.
// =============================================================================

#include "../../Shaders/Effects/filter/Corrupt.hlsl"

void NM_Corrupt_float(
    float             Intensity,
    float             BandHeight,
    float             Sort,
    float             Shift,
    float             ChannelShift,
    float             Melt,
    float             Scatter,
    float             Bits,
    int               Speed,
    int               Seed,
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    // Bridge node inputs into the core function's module-scope named uniforms.
    intensity    = Intensity;
    bandHeight   = BandHeight;
    sort         = Sort;
    shift        = Shift;
    channelShift = ChannelShift;
    melt         = Melt;
    scatter      = Scatter;
    bits         = Bits;
    speed        = Speed;
    seed         = Seed;

    // Reconstruct pixel-centered fragCoord (pos.xy) from the 0..1 UV: the WGSL
    // body recomputes uv = fragCoord / textureDimensions(inputTex), so fragCoord
    // must equal UV * tex-size for an identical result.
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 fragCoord = UV * float2(tw, th);

    Out = nm_corrupt(InputTex.tex, SS.samplerstate, fragCoord);
}

#endif // NM_CORRUPT_SG_INCLUDED
