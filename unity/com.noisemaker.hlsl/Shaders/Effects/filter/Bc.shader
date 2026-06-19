Shader "Noisemaker/filter/bc"
{
    // filter/bc — Brightness and Contrast adjustment (deprecated; use filter/adjust).
    // Single render pass ("bc"). Inputs: inputTex. Uniforms: brightness, contrast.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "bc" (definition.js passes[0].program)
        Pass
        {
            Name "bc"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Bc.hlsl"

            // Input surface. Bilinear, clamp-to-edge, LINEAR (non-sRGB) to match
            // the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: uv = pos.xy / vec2<f32>(textureDimensions(inputTex));
                // pos = @builtin(position) (top-left, +0.5). NM_FragCoord(i) is
                // the HLSL analog. Divide by the INPUT TEXTURE's own size.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                float4 color = inputTex.Sample(sampler_inputTex, uv);
                return nm_bc(color);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
