Shader "Noisemaker/filter/emboss"
{
    // filter/emboss — 3×3 emboss convolution (raised-relief appearance).
    // Single render pass ("emboss"). One per-effect uniform: amount (float, default 1.0).
    // Ported pixel-identically from shaders/effects/filter/emboss/wgsl/emboss.wgsl.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass name matches definition.js passes[0].program = "emboss"
        Pass
        {
            Name "emboss"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Emboss.hlsl"

            // Input surface. Sampler: bilinear, clamp-to-edge, linear (non-sRGB) — H7.
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: texSize = vec2<f32>(textureDimensions(inputTex))
                //        uv     = pos.xy / texSize
                // Divide by INPUT TEXTURE dimensions (not fullResolution).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize   = float2(tw, th);
                float2 uv        = NM_FragCoord(i) / texSize;
                float2 texelSize = 1.0 / texSize;

                // WGSL: origColor = textureSample(inputTex, inputSampler, uv)
                float4 origColor = inputTex.Sample(sampler_inputTex, uv);

                return nm_emboss(inputTex, sampler_inputTex, uv, texelSize, origColor);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
