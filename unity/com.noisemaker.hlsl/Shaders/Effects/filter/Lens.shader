Shader "Noisemaker/filter/lens"
{
    // filter/lens — barrel or pincushion lens distortion with optional antialias.
    // Single render pass (progName "lens"). RGB and alpha are both warped.
    // The runtime binds inputTex and per-effect uniforms via MaterialPropertyBlock.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "lens" (definition.js passes[0].program)
        Pass
        {
            Name "lens"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_lens
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Lens.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
