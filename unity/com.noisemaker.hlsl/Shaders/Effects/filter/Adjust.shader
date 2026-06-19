Shader "Noisemaker/filter/adjust"
{
    // filter/adjust — colorspace reinterpretation (rgb/hsv/oklab/oklch) +
    // hue/saturation + brightness/contrast. Single render pass.
    // Properties are for the inspector only; the runtime binds these via
    // MaterialPropertyBlock by their reference uniform names
    // (mode/rotation/hueRange/saturation/brightness/contrast) and binds the
    // input surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "adjust" (definition.js passes[0].program)
        Pass
        {
            Name "adjust"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Adjust.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let texSize = vec2<f32>(textureDimensions(inputTex));
                //   let uv = pos.xy / texSize;
                // pos = @builtin(position) (top-left, +0.5). NM_FragCoord(i) is
                // the HLSL analog. Divide by the INPUT TEXTURE's own size (NOT
                // fullResolution); no min-clamp (adjust.wgsl does not clamp).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2((float)tw, (float)th);
                float2 uv = NM_FragCoord(i) / texSize;

                float4 color = inputTex.Sample(sampler_inputTex, uv);
                return nm_adjust(color);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
