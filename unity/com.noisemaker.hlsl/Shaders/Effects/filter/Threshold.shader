Shader "Noisemaker/filter/threshold"
{
    // filter/threshold — binary threshold with adjustable edge softness.
    // Luminance (Rec.601) is smoothstepped across [level-sharpness, level+sharpness]
    // and written to RGB (alpha = 1). Single render pass.
    // Properties are for the inspector only; the runtime binds these via
    // MaterialPropertyBlock by their reference uniform names (level/sharpness)
    // and binds the input surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "thresh" (definition.js passes[0].program)
        Pass
        {
            Name "thresh"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Threshold.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: st = position.xy / vec2<f32>(textureDimensions(inputTex, 0));
                // pos = @builtin(position) (top-left, +0.5). NM_FragCoord(i) is the
                // HLSL analog. Divide by the INPUT TEXTURE's own size (not fullRes).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 st = NM_FragCoord(i) / texSize;

                float4 c = inputTex.Sample(sampler_inputTex, st);
                return nm_threshold(c);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
