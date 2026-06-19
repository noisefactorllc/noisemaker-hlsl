#ifndef NM_REPEAT_SG_INCLUDED
#define NM_REPEAT_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Repeat.hlsl
//
// Shader Graph Custom Function wrapper for filter/repeat. Add a Custom Function
// node, point it at this file, select NM_Repeat_float, and wire the inputs.
// Outputs RGBA (alpha always 1.0).
//
// filter/repeat is a SINGLE-PASS filter. This wrapper drives the same math as
// the render pass for use in a Shader Graph context. The caller supplies the
// sampled UV; wrap mode is an int (mirror=0, repeat=1, clamp=2).
//
// NOTE: The aspect ratio used here comes from the engine-provided _NM_AspectRatio
// (aliased as `aspectRatio` in NMFullscreen). In Shader Graph, wire the engine
// float into the AspectRatio input or supply a computed value.
// =============================================================================

#include "../../Shaders/Include/NMFullscreen.hlsl"
#include "../../Shaders/Effects/filter/Repeat.hlsl"

// InputTex   : source surface to tile
// SS         : sampler state (bilinear, clamp, linear/non-sRGB)
// UV         : 0..1 fragment UV (top-left origin, WGSL convention)
// X          : repeat count X (default 3)
// Y          : repeat count Y (default 3)
// OffsetX    : tile offset X (default 0)
// OffsetY    : tile offset Y (default 0)
// Wrap       : wrap mode int (mirror=0, repeat=1, clamp=2; default 1)
void NM_Repeat_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             X,
    float             Y,
    float             OffsetX,
    float             OffsetY,
    int               Wrap,
    out float4        Out)
{
    float2 st = UV;

    float aspect = aspectRatio;
    st.x = st.x * aspect;

    st = st * float2(X, Y) + float2(OffsetX * aspect, OffsetY);

    st.x = st.x / aspect;

    [branch]
    if (Wrap == 0) {
        // mirror
        st = abs(nm_mod(nm_mod(st + 1.0, float2(2.0, 2.0)) + 2.0, float2(2.0, 2.0)) - 1.0);
    } else if (Wrap == 1) {
        // repeat
        st = nm_mod(nm_mod(st, float2(1.0, 1.0)) + 1.0, float2(1.0, 1.0));
    } else {
        // clamp
        st = clamp(st, float2(0.0, 0.0), float2(1.0, 1.0));
    }

    Out = float4(InputTex.Sample(SS, st).rgb, 1.0);
}

#endif // NM_REPEAT_SG_INCLUDED
