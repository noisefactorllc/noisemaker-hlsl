Shader "Noisemaker/filter/celShading"
{
    // filter/celShading — cartoon-style shading with posterization + Sobel outlines.
    // THREE render passes driven in order by the C# runtime:
    //   celShadingColor : inputTex            -> celShadingColorTex
    //   celShadingEdges : celShadingColorTex  -> celShadingEdgeTex
    //   celShadingBlend : inputTex + celShadingColorTex + celShadingEdgeTex -> outputTex
    // The runtime rebinds the textures per pass and binds params via
    // MaterialPropertyBlock by their reference uniform names. Properties are for the
    // inspector only.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "celShadingColor" (definition.js passes[0].program)
        Pass
        {
            Name "celShadingColor"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment fragCelShadingColor
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "CelShading.hlsl"
            ENDHLSL
        }

        // progName "celShadingEdges" (definition.js passes[1].program)
        Pass
        {
            Name "celShadingEdges"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment fragCelShadingEdges
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "CelShading.hlsl"
            ENDHLSL
        }

        // progName "celShadingBlend" (definition.js passes[2].program)
        Pass
        {
            Name "celShadingBlend"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment fragCelShadingBlend
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "CelShading.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
