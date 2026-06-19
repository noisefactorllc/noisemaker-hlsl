Shader "Noisemaker/filter/convolutionFeedback"
{
    // filter/convolutionFeedback — three-pass temporal-feedback effect.
    //   cfSharpen: unsharp-mask the previous-frame feedback surface (selfTex) ->
    //              transient _cfSharpened.
    //   cfBlur:    Gaussian-blur _cfSharpened -> transient _cfBlurred.
    //   cfBlend:   lerp(input, _cfBlurred, intensity) -> output (resetState bypasses).
    // The output surface is double-buffered by the runtime so cfSharpen reads the
    // PREVIOUS frame's output as its feedback input (ping-pong). The runtime drives
    // the three passes in order and rebinds inputTex/feedbackTex per pass.
    // Inspector-only Properties; the runtime binds params + textures via
    // MaterialPropertyBlock using the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "cfSharpen" (definition.js passes[0].program) — unsharp mask of feedback
        Pass
        {
            Name "cfSharpen"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_cfSharpen
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ConvolutionFeedback.hlsl"
            ENDHLSL
        }

        // progName "cfBlur" (definition.js passes[1].program) — Gaussian blur
        Pass
        {
            Name "cfBlur"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_cfBlur
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ConvolutionFeedback.hlsl"
            ENDHLSL
        }

        // progName "cfBlend" (definition.js passes[2].program) — blend feedback with input
        Pass
        {
            Name "cfBlend"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_cfBlend
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ConvolutionFeedback.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
