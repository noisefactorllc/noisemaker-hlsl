Shader "Noisemaker/classicNoisedeck/moodscape"
{
    // classicNoisedeck/moodscape — refracted value noise with multiple color
    // modes. Single render pass, generator (no texture inputs). Runtime binds
    // params via MaterialPropertyBlock by the names declared in Moodscape.hlsl
    // (NOISE_TYPE, COLOR_MODE, noiseScale, speed, refractAmt, ridges, wrap,
    // seed, hueRotation, hueRange, intensity). The Properties block is for
    // inspector convenience only; values come from the MaterialPropertyBlock
    // at render time.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "moodscape" (definition.js passes[0].program)
        Pass
        {
            Name "moodscape"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "Moodscape.hlsl"

            // No texture inputs (generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_moodscape(globalCoord, resolution, fullResolution, time);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
