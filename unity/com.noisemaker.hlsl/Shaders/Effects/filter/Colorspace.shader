Shader "Noisemaker/filter/colorspace"
{
    // filter/colorspace — reinterpret RGB as HSV, OKLab, or OKLCH and convert to RGB.
    // Single render pass (definition.js passes[0].program "colorspace").
    // Parameter: mode (int, default 0: hsv, 1: oklab, 2: oklch).
    // The runtime binds the input surface to inputTex and mode uniform via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "colorspace" (definition.js passes[0].program)
        Pass
        {
            Name "colorspace"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Colorspace.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
                //        let uv = pos.xy / texSize;
                // pos = @builtin(position) (top-left, +0.5). NM_FragCoord(i) is the
                // HLSL analog. Divide by the INPUT TEXTURE's own dimensions (not fullResolution).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                float4 color = inputTex.Sample(sampler_inputTex, uv);
                return nm_colorspace(color);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
