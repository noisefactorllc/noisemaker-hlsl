#ifndef NM_NORMALMAP_SG_INCLUDED
#define NM_NORMALMAP_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/NormalMap.hlsl
//
// Shader Graph Custom Function wrapper for filter/normalMap.
// Add a Custom Function node, point it at this file, select NM_NormalMap_float,
// and wire the InputTex/SS/UV inputs. Outputs RGBA normal-map color.
//
// NOTE: The core function uses Texture2D.Load (integer texel fetch), so UV is
// used only to derive the integer pixel coordinate (UV * texDimensions). This
// matches the WGSL textureLoad path exactly.
// =============================================================================

#include "../../Shaders/Effects/filter/NormalMap.hlsl"

// InputTex : source surface for normal-map generation
// SS       : sampler state (declared for API completeness; Load path does not sample)
// UV       : 0..1 fragment UV (top-left origin, WGSL convention)
void NM_NormalMap_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    out float4        Out)
{
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    int2 fragCoord = int2((int)(UV.x * (float)tw), (int)(UV.y * (float)th));
    Out = nm_normalMap(InputTex.tex, fragCoord);
}

#endif // NM_NORMALMAP_SG_INCLUDED
