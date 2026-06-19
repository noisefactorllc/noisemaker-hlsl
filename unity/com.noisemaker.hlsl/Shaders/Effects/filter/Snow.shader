Shader "Noisemaker/filter/snow"
{
    // filter/snow — TV static noise blended over the input image.
    // Single render pass. RGB is modulated; alpha is passed through.
    // The runtime binds alpha, pause, density, and inputTex via
    // MaterialPropertyBlock using the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "snow" (definition.js passes[0].program)
        Pass
        {
            Name "snow"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_snow
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Snow.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
