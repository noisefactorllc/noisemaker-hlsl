Shader "Noisemaker/filter/spiral"
{
    // filter/spiral — spiral distortion via polar-coordinate warp.
    // Single render pass. Uniform names match definition.js globals[*].uniform
    // and are bound at runtime via MaterialPropertyBlock.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "spiral" (definition.js passes[0].program)
        Pass
        {
            Name "spiral"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_spiral
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Spiral.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
