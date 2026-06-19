Shader "Noisemaker/filter/zoomBlur"
{
    // filter/zoomBlur — radial / zoom blur emanating from frame center. 41
    // weighted, jittered samples along the toward-center vector. Single render
    // pass. Output alpha forced to 1.0. Inspector-only Properties; the runtime
    // binds these (and the inputTex sampler) via MaterialPropertyBlock using the
    // reference uniform names (strength).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "zoomBlur" (definition.js passes[0].program)
        Pass
        {
            Name "zoomBlur"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_zoomBlur
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ZoomBlur.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
