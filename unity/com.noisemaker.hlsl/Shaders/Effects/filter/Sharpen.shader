Shader "Noisemaker/filter/sharpen"
{
    // filter/sharpen — Sharpen convolution using a 3x3 kernel.
    // Single render pass. Per-effect param: amount (float, default 1.0).
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "sharpen" (definition.js passes[0].program)
        Pass
        {
            Name "sharpen"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Sharpen.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
                //        let uv = pos.xy / texSize;
                // Divide NM_FragCoord (top-left, +0.5) by the INPUT TEXTURE's
                // own dimensions — not fullResolution. Mirrors the WGSL exactly.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                return nm_sharpen(inputTex, sampler_inputTex, uv, texSize);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
