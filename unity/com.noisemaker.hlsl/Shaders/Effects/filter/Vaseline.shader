Shader "Noisemaker/filter/vaseline"
{
    // filter/vaseline — N-tap golden-angle-spiral blur with edge-weighted
    // blending and brightness boost. Single render pass (progName "upsample").
    // RGB is processed; alpha is passed through unchanged.
    // The runtime binds inputTex and alpha via MaterialPropertyBlock.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "upsample" (definition.js passes[0].program)
        Pass
        {
            Name "upsample"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_upsample
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Vaseline.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
