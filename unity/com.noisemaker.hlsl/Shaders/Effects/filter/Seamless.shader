Shader "Noisemaker/filter/seamless"
{
    // filter/seamless — edge-blend cross-fade for seamless tiling.
    // Single render pass (progName "seamless"). Three per-effect uniforms.
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass: progName "seamless" (definition.js passes[0].program)
        Pass
        {
            Name "seamless"
            HLSLPROGRAM
            #pragma vertex   NMVertFullscreen
            #pragma fragment NMFrag_seamless
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles

            #include "Seamless.hlsl"

            ENDHLSL
        }
    }
    Fallback Off
}
