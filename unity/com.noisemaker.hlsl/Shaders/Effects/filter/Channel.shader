Shader "Noisemaker/filter/channel"
{
    // filter/channel — Channel isolation as grayscale with scale/offset/frac.
    // Single render pass. definition.js passes[0].program = "channel".
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "channel" (definition.js passes[0].program)
        Pass
        {
            Name "channel"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Channel.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let st = position.xy / vec2<f32>(textureDimensions(inputTex, 0));
                // Divide by the INPUT TEXTURE's own dimensions, NOT fullResolution.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                float4 c = inputTex.Sample(sampler_inputTex, uv);
                return nm_channel(c);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
