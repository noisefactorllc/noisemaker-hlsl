Shader "Noisemaker/filter/scanlineError"
{
    // filter/scanlineError — scanline glitch / VHS tape artifacts. Single render
    // pass with two runtime-selected modes (mode: 0 scanline, 1 vhs). The input
    // is point-fetched (.Load) at integer texel coords with a horizontal noise
    // displacement, plus mode-specific noise compositing. Inspector-only
    // Properties; the runtime binds these and the inputTex sampler via
    // MaterialPropertyBlock using the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "scanlineError" (definition.js passes[0].program)
        Pass
        {
            Name "scanlineError"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_scanlineError
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ScanlineError.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
