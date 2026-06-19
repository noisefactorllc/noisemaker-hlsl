Shader "Noisemaker/filter/ridge"
{
    // filter/ridge — ridge/crease enhancement with configurable midpoint.
    // Single render pass. One parameter: level (float, default 0.5, range [0,1]).
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "ridge" (definition.js passes[0].program)
        Pass
        {
            Name "ridge"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Ridge.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // GLSL: uv = gl_FragCoord.xy / vec2(textureSize(inputTex, 0))
                // Divide by the INPUT TEXTURE's own size (not fullResolution).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                float4 texel = inputTex.Sample(sampler_inputTex, uv);
                return nm_ridge(texel, level);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
