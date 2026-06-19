#ifndef NM_SPECTRUM_SG_INCLUDED
#define NM_SPECTRUM_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/Spectrum.hlsl
//
// Shader Graph Custom Function wrapper for synth/spectrum. Add a Custom
// Function node, point it at this file, select NM_Spectrum_float, and wire
// the named inputs. Outputs RGBA.
//
// AudioSpectrum0..31 supply the 32 float4 bins (128 total frequency bins).
// The core nm_spectrum() in Shaders/Effects/synth/Spectrum.hlsl reads the
// effect parameters from named global uniforms. This wrapper copies each node
// input into the corresponding global before calling the core.
//
// NOTE: audioSpectrum is a float4[32] array uniform — Shader Graph Custom
// Function nodes cannot expose array inputs directly. Pass individual float4
// slots (AudioSpectrum0..AudioSpectrum31) and assemble them here.
// =============================================================================

#include "../../Shaders/Effects/synth/Spectrum.hlsl"

void NM_Spectrum_float(
    float3 LineColor,
    float  LineThickness,
    float  Gain,
    float4 AS0,  float4 AS1,  float4 AS2,  float4 AS3,
    float4 AS4,  float4 AS5,  float4 AS6,  float4 AS7,
    float4 AS8,  float4 AS9,  float4 AS10, float4 AS11,
    float4 AS12, float4 AS13, float4 AS14, float4 AS15,
    float4 AS16, float4 AS17, float4 AS18, float4 AS19,
    float4 AS20, float4 AS21, float4 AS22, float4 AS23,
    float4 AS24, float4 AS25, float4 AS26, float4 AS27,
    float4 AS28, float4 AS29, float4 AS30, float4 AS31,
    float2 UV,
    float2 Resolution,
    out float4 Out)
{
    // Bridge node inputs -> named global uniforms.
    lineColor     = LineColor;
    lineThickness = LineThickness;
    gain          = Gain;

    // Assemble flat array from individual inputs.
    audioSpectrum[0]  = AS0;  audioSpectrum[1]  = AS1;
    audioSpectrum[2]  = AS2;  audioSpectrum[3]  = AS3;
    audioSpectrum[4]  = AS4;  audioSpectrum[5]  = AS5;
    audioSpectrum[6]  = AS6;  audioSpectrum[7]  = AS7;
    audioSpectrum[8]  = AS8;  audioSpectrum[9]  = AS9;
    audioSpectrum[10] = AS10; audioSpectrum[11] = AS11;
    audioSpectrum[12] = AS12; audioSpectrum[13] = AS13;
    audioSpectrum[14] = AS14; audioSpectrum[15] = AS15;
    audioSpectrum[16] = AS16; audioSpectrum[17] = AS17;
    audioSpectrum[18] = AS18; audioSpectrum[19] = AS19;
    audioSpectrum[20] = AS20; audioSpectrum[21] = AS21;
    audioSpectrum[22] = AS22; audioSpectrum[23] = AS23;
    audioSpectrum[24] = AS24; audioSpectrum[25] = AS25;
    audioSpectrum[26] = AS26; audioSpectrum[27] = AS27;
    audioSpectrum[28] = AS28; audioSpectrum[29] = AS29;
    audioSpectrum[30] = AS30; audioSpectrum[31] = AS31;

    // Seed engine globals so fullResolution/resolution aliases resolve.
    _NM_Resolution     = float4(Resolution, 0.0, 0.0);
    _NM_FullResolution = float4(Resolution, 0.0, 0.0);

    // fragCoord = UV * resolution (pixel-centered at texel center).
    float2 fragCoordXY = UV * Resolution;
    Out = nm_spectrum(fragCoordXY);
}

#endif // NM_SPECTRUM_SG_INCLUDED
