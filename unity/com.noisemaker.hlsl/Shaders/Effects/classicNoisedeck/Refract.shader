Shader "Noisemaker/classicNoisedeck/refract"
{
    // classicNoisedeck/refract — noise-based UV warp with 18 blend modes.
    // Single render pass (filter). RGB+alpha output.
    // The runtime binds inputTex and all uniforms via MaterialPropertyBlock.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "refract" (definition.js passes[0].program)
        Pass
        {
            Name "refract"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_refract
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Refract.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
