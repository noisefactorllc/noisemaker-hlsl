Shader "Noisemaker/filter/vignette"
{
    // filter/vignette — radial edge darkening with brightness blend + alpha
    // crossfade. Single render pass. RGB is affected; alpha is passed through.
    // Inspector-only Properties. The runtime binds these (and the inputTex
    // sampler) via MaterialPropertyBlock using the reference uniform names
    // (vignetteBrightness, alpha).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "vignette" (definition.js passes[0].program)
        Pass
        {
            Name "vignette"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_vignette
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Vignette.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
