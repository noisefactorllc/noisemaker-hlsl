Shader "Noisemaker/synth/osc2d"
{
    // synth/osc2d — 2D oscillator pattern generator. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Osc2d.hlsl (oscType, frequency, speed, rotation, seed). The Properties
    // block below is for inspector convenience only; values come from the
    // MaterialPropertyBlock at render time.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "osc2d" (definition.js passes[0].program)
        Pass
        {
            Name "osc2d"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_osc2d
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (hashes are bit-sensitive).
            #pragma exclude_renderers gles
            #include "Osc2d.hlsl"

            // No texture inputs (synth generator).
            ENDHLSL
        }
    }
    Fallback Off
}
