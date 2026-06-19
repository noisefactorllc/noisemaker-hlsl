#ifndef NM_SCOPE_SG_INCLUDED
#define NM_SCOPE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Scope.hlsl
//
// Shader Graph Custom Function wrapper for synth/scope. Add a Custom Function
// node, point it at this file, select NM_Scope_float, and wire the named
// inputs. Outputs RGBA.
//
// The core nm_scope() reads lineColor/lineThickness/gain/audioWaveform from
// named global uniforms declared in Scope.hlsl. This wrapper bridges node
// inputs into those globals before calling the core. The audioWaveform array
// is passed as a flat float4[32] input (128 samples packed as the WGSL does).
//
// NOTE: audioWaveform is runtime audio data; in a Shader Graph node context
// it must be wired from a script-driven property or left at default (silence).
// =============================================================================

#include "../../Shaders/Effects/synth/Scope.hlsl"

void NM_Scope_float(
    float2   UV,
    float2   Resolution,
    float3   LineColor,
    float    LineThickness,
    float    Gain,
    float4   AudioWaveform0,
    float4   AudioWaveform1,
    float4   AudioWaveform2,
    float4   AudioWaveform3,
    float4   AudioWaveform4,
    float4   AudioWaveform5,
    float4   AudioWaveform6,
    float4   AudioWaveform7,
    float4   AudioWaveform8,
    float4   AudioWaveform9,
    float4   AudioWaveform10,
    float4   AudioWaveform11,
    float4   AudioWaveform12,
    float4   AudioWaveform13,
    float4   AudioWaveform14,
    float4   AudioWaveform15,
    float4   AudioWaveform16,
    float4   AudioWaveform17,
    float4   AudioWaveform18,
    float4   AudioWaveform19,
    float4   AudioWaveform20,
    float4   AudioWaveform21,
    float4   AudioWaveform22,
    float4   AudioWaveform23,
    float4   AudioWaveform24,
    float4   AudioWaveform25,
    float4   AudioWaveform26,
    float4   AudioWaveform27,
    float4   AudioWaveform28,
    float4   AudioWaveform29,
    float4   AudioWaveform30,
    float4   AudioWaveform31,
    out float4 Out)
{
    // Bridge node inputs -> core named globals.
    lineColor     = LineColor;
    lineThickness = LineThickness;
    gain          = Gain;

    audioWaveform[0]  = AudioWaveform0;
    audioWaveform[1]  = AudioWaveform1;
    audioWaveform[2]  = AudioWaveform2;
    audioWaveform[3]  = AudioWaveform3;
    audioWaveform[4]  = AudioWaveform4;
    audioWaveform[5]  = AudioWaveform5;
    audioWaveform[6]  = AudioWaveform6;
    audioWaveform[7]  = AudioWaveform7;
    audioWaveform[8]  = AudioWaveform8;
    audioWaveform[9]  = AudioWaveform9;
    audioWaveform[10] = AudioWaveform10;
    audioWaveform[11] = AudioWaveform11;
    audioWaveform[12] = AudioWaveform12;
    audioWaveform[13] = AudioWaveform13;
    audioWaveform[14] = AudioWaveform14;
    audioWaveform[15] = AudioWaveform15;
    audioWaveform[16] = AudioWaveform16;
    audioWaveform[17] = AudioWaveform17;
    audioWaveform[18] = AudioWaveform18;
    audioWaveform[19] = AudioWaveform19;
    audioWaveform[20] = AudioWaveform20;
    audioWaveform[21] = AudioWaveform21;
    audioWaveform[22] = AudioWaveform22;
    audioWaveform[23] = AudioWaveform23;
    audioWaveform[24] = AudioWaveform24;
    audioWaveform[25] = AudioWaveform25;
    audioWaveform[26] = AudioWaveform26;
    audioWaveform[27] = AudioWaveform27;
    audioWaveform[28] = AudioWaveform28;
    audioWaveform[29] = AudioWaveform29;
    audioWaveform[30] = AudioWaveform30;
    audioWaveform[31] = AudioWaveform31;

    // Seed engine-resolution globals for nm_scope's resolution.y usage.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);

    // fragCoord = UV * resolution (pixel-centered at texel center).
    float2 fragCoord = UV * Resolution;
    Out = nm_scope(fragCoord);
}

#endif // NM_SCOPE_SG_INCLUDED
