Shader "Noisemaker/filter/blur"
{
    // filter/blur — two-pass separable Gaussian blur. blurH blurs along X into an
    // internal _blurTemp target; blurV blurs along Y into the output. The runtime
    // drives the two passes in order and rebinds inputTex per pass (inputTex ->
    // _blurTemp -> outputTex). Inspector-only Properties. The runtime binds these
    // (and the inputTex sampler) via MaterialPropertyBlock using the reference
    // uniform names (radiusX, radiusY).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "blurH" (definition.js passes[0].program) — horizontal pass
        Pass
        {
            Name "blurH"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment fragBlurH
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Blur.hlsl"
            ENDHLSL
        }

        // progName "blurV" (definition.js passes[1].program) — vertical pass
        Pass
        {
            Name "blurV"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment fragBlurV
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Blur.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
