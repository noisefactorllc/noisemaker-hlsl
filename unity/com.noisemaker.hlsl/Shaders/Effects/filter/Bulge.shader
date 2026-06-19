Shader "Noisemaker/filter/bulge"
{
    // filter/bulge — Bulge distortion from center.
    // Single render pass (program "bulge", definition.js passes[0]).
    // One input: inputTex (definition.js passes[0].inputs.inputTex).
    // The runtime binds the input surface via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass name matches definition.js passes[0].program = "bulge"
        Pass
        {
            Name "bulge"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_bulge
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles

            #include "Bulge.hlsl"

            // Uniforms bound by the runtime via MaterialPropertyBlock.
            // Names match definition.js globals[*].uniform exactly.
            // Texture2D + SamplerState declared in Bulge.hlsl.
            // scalar uniforms declared in Bulge.hlsl.
            ENDHLSL
        }
    }
    Fallback Off
}
