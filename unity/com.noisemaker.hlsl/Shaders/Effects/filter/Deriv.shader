Shader "Noisemaker/filter/deriv"
{
    // filter/deriv — Derivative-based edge detection.
    // Single render pass (program "deriv"). One per-effect param: float amount.
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "deriv" (definition.js passes[0].program)
        Pass
        {
            Name "deriv"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Deriv.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
                //        let uv = pos.xy / texSize;
                // pos = @builtin(position) (top-left, +0.5). NM_FragCoord(i) is
                // the HLSL analog. Divide by the INPUT TEXTURE's own size (not
                // fullResolution — the WGSL divides by textureDimensions(inputTex)).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                return nm_deriv(inputTex, sampler_inputTex, uv, texSize);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
