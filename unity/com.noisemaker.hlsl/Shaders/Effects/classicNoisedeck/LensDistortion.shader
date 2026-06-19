Shader "Noisemaker/classicNoisedeck/lensDistortion"
{
    // classicNoisedeck/lensDistortion — barrel/pincushion distortion with
    // chromatic/prismatic aberration, animated shape-distance, tint-reflect,
    // and vignette. Single render pass (progName "lensDistortion").
    //
    // Inspector properties — the runtime binds these (and inputTex) via
    // MaterialPropertyBlock using the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "lensDistortion" (definition.js passes[0].program)
        Pass
        {
            Name "lensDistortion"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_lensDistortion
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "LensDistortion.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
