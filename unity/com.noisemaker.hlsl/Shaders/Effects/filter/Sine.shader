Shader "Noisemaker/filter/sine"
{
    // filter/sine — Sine wave color transform.
    // Single render pass ("sine"). Two uniforms: amount (float), colorMode (float).
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "sine" (definition.js passes[0].program)
        Pass
        {
            Name "sine"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Sine.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: uv = pos.xy / vec2<f32>(textureDimensions(inputTex));
                // Divide by the INPUT TEXTURE's own size, not fullResolution.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                float4 color = inputTex.Sample(sampler_inputTex, uv);
                return nm_sine(color);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
