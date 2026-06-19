Shader "Noisemaker/filter/grade"
{
    // filter/grade — six-pass linear color-grading chain. Each pass reads its
    // predecessor's persistent intermediate target and writes the next:
    //   primary      : inputTex      -> _primaryTex
    //   creative     : _primaryTex   -> _creativeTex
    //   wheels       : _creativeTex  -> _wheelsTex
    //   hslSecondary : _wheelsTex    -> _hslTex
    //   lut          : _hslTex       -> _lutTex
    //   vignette     : _lutTex       -> outputTex
    // The runtime drives the six passes in order and rebinds inputTex per pass.
    // No MRT, no repeat, no feedback. Inspector-only Properties; the runtime
    // binds these (and the inputTex sampler) via MaterialPropertyBlock using the
    // reference uniform names from definition.js globals.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "primary" (definition.js passes[0].program)
        Pass
        {
            Name "primary"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_primary
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Grade.hlsl"
            ENDHLSL
        }

        // progName "creative" (definition.js passes[1].program)
        Pass
        {
            Name "creative"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_creative
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Grade.hlsl"
            ENDHLSL
        }

        // progName "wheels" (definition.js passes[2].program)
        Pass
        {
            Name "wheels"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_wheels
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Grade.hlsl"
            ENDHLSL
        }

        // progName "hslSecondary" (definition.js passes[3].program)
        Pass
        {
            Name "hslSecondary"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_hslSecondary
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Grade.hlsl"
            ENDHLSL
        }

        // progName "lut" (definition.js passes[4].program)
        Pass
        {
            Name "lut"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_lut
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Grade.hlsl"
            ENDHLSL
        }

        // progName "vignette" (definition.js passes[5].program)
        Pass
        {
            Name "vignette"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_vignette
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Grade.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
