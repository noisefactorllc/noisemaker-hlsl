Shader "Noisemaker/filter/crt"
{
    // filter/crt — CRT monitor simulation.
    // Scanlines, lens warp, chromatic aberration, hue shift, saturation boost,
    // vignette, contrast normalization. Single render pass. RGB affected; alpha
    // passed through unchanged.
    // Inspector-only Properties. The runtime binds these (and the inputTex
    // sampler) via MaterialPropertyBlock using the reference uniform names
    // (alpha, speed, seed).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "crt" (definition.js passes[0].program)
        Pass
        {
            Name "crt"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_crt
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Crt.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
