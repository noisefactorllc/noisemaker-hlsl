Shader "Noisemaker/filter/chromaticAberration"
{
    // filter/chromaticAberration — color fringing simulating lens aberration.
    // Single render pass. R/B channels sampled at aspect-corrected offsets;
    // alpha passed through from the unshifted (green) sample.
    // Inspector-only Properties. The runtime binds these (and the inputTex
    // sampler) via MaterialPropertyBlock using the reference uniform names
    // (aberrationAmt, passthru).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "chromaticAberration" (definition.js passes[0].program)
        Pass
        {
            Name "chromaticAberration"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_chromaticAberration
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ChromaticAberration.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
