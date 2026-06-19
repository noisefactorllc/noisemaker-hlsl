Shader "Noisemaker/filter/lightLeak"
{
    // filter/lightLeak — Voronoi-based colored light leak overlay with wormhole
    // distortion, bloom approximation, screen blend, center mask, and vaseline
    // soft blur. Single render pass. RGB is affected; alpha is passed through.
    // Inspector-only Properties. The runtime binds these (and the inputTex
    // sampler) via MaterialPropertyBlock using the reference uniform names
    // (alpha, color, speed, seed).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "lightLeak" (definition.js passes[0].program)
        Pass
        {
            Name "lightLeak"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_lightLeak
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "LightLeak.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
