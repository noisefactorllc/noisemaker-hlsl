Shader "Noisemaker/filter/grain"
{
    // filter/grain — film grain: blends the source image with animated value
    // noise (bicubic value noise over x/y/time). Single render pass. RGB is
    // affected; alpha passes through. The runtime binds these (and the inputTex
    // sampler) via MaterialPropertyBlock using the reference uniform names
    // (alpha, pause).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "grain" (definition.js passes[0].program)
        Pass
        {
            Name "grain"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_grain
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Grain.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
