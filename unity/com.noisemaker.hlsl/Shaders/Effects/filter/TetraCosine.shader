Shader "Noisemaker/filter/tetraCosine"
{
    // filter/tetraCosine — Cosine palette applied to input image luminance.
    // Single render pass ("tetraCosine" program from definition.js).
    // Supports RGB, HSV, OkLab, OKLCH color modes.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "tetraCosine" (definition.js passes[0].program)
        Pass
        {
            Name "tetraCosine"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "TetraCosine.hlsl"

            // Input surface. Bilinear, clamp-to-edge, LINEAR (non-sRGB).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: uv = position.xy / vec2<f32>(textureDimensions(inputTex, 0))
                // NM_FragCoord(i) is the top-left, +0.5-centered HLSL analog.
                // Division by input texture's own size (not fullResolution).
                return nm_tetraCosine(inputTex, sampler_inputTex, NM_FragCoord(i));
            }
            ENDHLSL
        }
    }
    Fallback Off
}
