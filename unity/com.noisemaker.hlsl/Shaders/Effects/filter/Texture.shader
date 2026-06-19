Shader "Noisemaker/filter/texture"
{
    // filter/texture — generate a height field (canvas/crosshatch/halftone/paper/
    // stucco), shade from its gradient, then blend back into the source by alpha.
    // Single render pass. RGB is affected; alpha is passed through. Inspector-only
    // Properties. The runtime binds these (and the inputTex sampler) via
    // MaterialPropertyBlock using the reference uniform names (alpha, scale) plus
    // the mode define injected by its key MODE (globals.mode.define = "MODE").


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "texture" (definition.js passes[0].program)
        Pass
        {
            Name "texture"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_texture
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Texture.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
