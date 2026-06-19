Shader "Noisemaker/filter/repeat"
{
    // filter/repeat — Tiling repeat with mirror/repeat/clamp wrap modes.
    // Single render pass (definition.js passes[0].program "repeat").
    // The runtime binds inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass matches definition.js passes[0].program "repeat"
        Pass
        {
            Name "repeat"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Repeat.hlsl"

            // Input surface. Sampler: bilinear, clamp-to-edge, LINEAR (non-sRGB) — H7.
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                return nm_repeat(i, inputTex, sampler_inputTex);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
