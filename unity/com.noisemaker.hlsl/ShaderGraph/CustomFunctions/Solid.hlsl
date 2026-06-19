#ifndef NM_SG_SOLID_INCLUDED
#define NM_SG_SOLID_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for synth/solid.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   color  -> Color (float3)
//   alpha  -> Alpha (float)
// UV/Resolution are accepted for node-signature uniformity but unused, since
// the WGSL body produces a constant color with premultiplied alpha and reads
// no coordinates.
//
// Self-contained (does NOT include NMFullscreen.hlsl) so it is safe to drop
// into a Shader Graph Custom Function node. Mirrors nm_solid() in
// Shaders/Effects/synth/Solid.hlsl verbatim.
// =============================================================================

void NM_Solid_float(float3 Color, float Alpha, float2 UV, float2 Resolution, out float4 Out)
{
    // Premultiply RGB by alpha for correct compositing
    Out = float4(Color * Alpha, Alpha);
}

#endif // NM_SG_SOLID_INCLUDED
