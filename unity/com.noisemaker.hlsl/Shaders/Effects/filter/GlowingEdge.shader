Shader "Noisemaker/filter/glowingEdge"
{
    // filter/glowingEdge — single-pass Sobel edge detection with screen-blend glow.
    // One render pass (progName "glowingEdge"). Uniforms: sobelMetric, width, alpha.
    // The runtime binds inputTex and all uniforms via MaterialPropertyBlock.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "glowingEdge" (definition.js passes[0].program)
        Pass
        {
            Name "glowingEdge"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_glowingEdge
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "GlowingEdge.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
