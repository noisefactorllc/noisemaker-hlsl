Shader "Noisemaker/filter/tint"
{
    // filter/tint — colorize the input texture with a color overlay.
    // Modes: 0 overlay, 1 multiply, 2 recolor. Single render pass.
    // Properties are for the inspector only; the runtime binds these via
    // MaterialPropertyBlock by their reference uniform names (color/alpha/mode)
    // and binds the input surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "colorize" (definition.js passes[0].program)
        Pass
        {
            Name "colorize"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Tint.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let size = max(textureDimensions(inputTex, 0), vec2<u32>(1, 1));
                //   let st   = position.xy / vec2<f32>(size);
                // pos = @builtin(position) (top-left, +0.5). NM_FragCoord(i) is the
                // HLSL analog. Divide by the INPUT TEXTURE's own size (not fullRes),
                // clamped to a minimum of (1,1).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 size = float2(max(tw, 1u), max(th, 1u));
                float2 st = NM_FragCoord(i) / size;

                float4 base = inputTex.Sample(sampler_inputTex, st);
                return nm_tint(base);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
