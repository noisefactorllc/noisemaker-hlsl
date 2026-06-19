Shader "Noisemaker/filter/pinch"
{
    // filter/pinch — pinch distortion toward center.
    // Single render pass. Rotation, aspect-correct lens, wrap mode, optional AA.
    // Inspector-only Properties. The runtime binds these (and the inputTex
    // sampler) via MaterialPropertyBlock using the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "pinch" (definition.js passes[0].program)
        Pass
        {
            Name "pinch"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_pinch
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Pinch.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
