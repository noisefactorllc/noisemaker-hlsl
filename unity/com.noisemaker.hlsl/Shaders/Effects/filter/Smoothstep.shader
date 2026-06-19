Shader "Noisemaker/filter/smoothstep"
{
    // filter/smoothstep — Hermite smooth transition between edge0 and edge1.
    // Single render pass. Two float uniforms: edge0, edge1.
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "smoothstep" (definition.js passes[0].program)
        Pass
        {
            Name "smoothstep"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Smoothstep.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: uv = pos.xy / vec2<f32>(textureDimensions(inputTex));
                // pos = @builtin(position) (top-left, +0.5). NM_FragCoord(i) is
                // the HLSL analog. Divide by INPUT TEXTURE's own size (not fullRes).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                float4 color = inputTex.Sample(sampler_inputTex, uv);
                return nm_smoothstep(color);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
