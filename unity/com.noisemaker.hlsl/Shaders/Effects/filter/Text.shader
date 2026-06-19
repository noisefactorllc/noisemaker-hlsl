Shader "Noisemaker/filter/text"
{
    // filter/text — CPU-rendered text overlay with optional matte background.
    // Single render pass ("overlay"). Two input textures: inputTex (scene) and
    // textTex (CPU-rendered text, RGBA, alpha = text presence).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "text" (definition.js passes[0].program = "text")
        Pass
        {
            Name "overlay"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Text.hlsl"

            // Input scene surface. Bilinear, clamp-to-edge, linear (non-sRGB).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            // CPU-rendered text surface (RGBA, alpha = text presence).
            Texture2D    textTex;
            SamplerState sampler_textTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let size = max(textureDimensions(inputTex, 0), vec2<u32>(1,1));
                //        let uv  = position.xy / vec2<f32>(size);
                // Divide by the INPUT TEXTURE's own dimensions, not fullResolution.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(max(tw, 1u), max(th, 1u));
                float2 uv = NM_FragCoord(i) / texSize;

                float4 inputColor = inputTex.Sample(sampler_inputTex, uv);
                float4 text       = textTex.Sample(sampler_textTex,   uv);

                return nm_text(inputColor, text, matteColor, matteOpacity);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
