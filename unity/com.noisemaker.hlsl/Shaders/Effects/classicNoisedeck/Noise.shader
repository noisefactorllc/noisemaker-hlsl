Shader "Noisemaker/classicNoisedeck/noise"
{
    // classicNoisedeck/noise — animated multi-resolution noise synthesizer.
    // Single render pass (program "noise"). Generator (no texture inputs).
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Noise.hlsl (xScale, yScale, seed, ...; plus the int "compile-time" enums
    // NOISE_TYPE, COLOR_MODE, REFRACT_MODE, LOOP_OFFSET, METRIC bound as ints).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "noise" (definition.js passes[0].program)
        Pass
        {
            Name "noise"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "Noise.hlsl"

            // No texture inputs (generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_noise(globalCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
