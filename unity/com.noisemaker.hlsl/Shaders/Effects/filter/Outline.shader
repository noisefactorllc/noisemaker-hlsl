Shader "Noisemaker/filter/outline"
{
    // filter/outline — three-pass edge-stroke filter. outlineValueMap converts the
    // input to a perceptual-luminance value map (-> outlineValueMap target); outline
    // Sobel runs a 3x3 Sobel with a configurable distance metric and thickness
    // offset (-> outlineEdges target); outlineBlend darkens (or lightens, if
    // inverted) the base image where edges are detected (-> outputTex). The runtime
    // drives the three passes in order and rebinds the input textures per pass.
    // Inspector-only Properties. The runtime binds these (and the input texture
    // samplers) via MaterialPropertyBlock using the reference uniform names
    // (sobelMetric, thickness, invert).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "outlineValueMap" (definition.js passes[0].program) — luminance value map
        Pass
        {
            Name "outlineValueMap"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_outlineValueMap
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Outline.hlsl"
            ENDHLSL
        }

        // progName "outlineSobel" (definition.js passes[1].program) — Sobel edge detection
        Pass
        {
            Name "outlineSobel"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_outlineSobel
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Outline.hlsl"
            ENDHLSL
        }

        // progName "outlineBlend" (definition.js passes[2].program) — edge blend
        Pass
        {
            Name "outlineBlend"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_outlineBlend
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Outline.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
