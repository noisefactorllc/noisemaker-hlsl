#ifndef NM_COLORSPACE_SG_INCLUDED
#define NM_COLORSPACE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Colorspace.hlsl
//
// Shader Graph Custom Function wrapper for filter/colorspace. Drops the effect
// in as a node: add a Custom Function node, point it at this file, select
// NM_Colorspace_float, and wire the named inputs. Outputs RGBA.
//
// The core nm_colorspace(...) in Shaders/Effects/filter/Colorspace.hlsl reads
// the `mode` parameter from a module-scope named uniform — matching the runtime's
// individual-named-uniform binding model. In a standalone Shader Graph node that
// global is not bound by the runtime, so this wrapper assigns the node input to
// it before calling nm_colorspace, bridging the named input into the core function.
//
// Param mapping (definition.js globals[*].uniform -> node input):
//   Mode     : mode (0=hsv, 1=oklab, 2=oklch), default 0
//   InputTex : source surface
//   SS       : sampler state (bilinear, clamp, linear/non-sRGB) for InputTex
//   UV       : 0..1 fragment UV (top-left origin, WGSL convention)
// =============================================================================

#include "../../Shaders/Effects/filter/Colorspace.hlsl"

void NM_Colorspace_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    int               Mode,
    out float4        Out)
{
    // Bridge node input into the core function's module-scope named uniform.
    mode = Mode;

    float4 color = InputTex.Sample(SS, UV);
    Out = nm_colorspace(color);
}

#endif // NM_COLORSPACE_SG_INCLUDED
