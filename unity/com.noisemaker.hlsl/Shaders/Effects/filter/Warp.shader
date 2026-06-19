Shader "Noisemaker/filter/warp"
{
    // filter/warp — Perlin noise-based warp distortion. Single render pass.
    // Inspector-only Properties. The runtime binds these (and the inputTex
    // sampler) via MaterialPropertyBlock using the reference uniform names
    // (strength, scale, seed, speed, wrap, antialias).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "warp" (definition.js passes[0].program)
        Pass
        {
            Name "warp"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_warp
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Warp.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
