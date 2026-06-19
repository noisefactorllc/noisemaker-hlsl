Shader "Noisemaker/filter/step"
{
    // filter/step — Hard threshold at specified value, optional antialiasing.
    // Single render pass ("step"). One per-effect param: threshold (float),
    // antialias (int bool).
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "step" (definition.js passes[0].program)
        Pass
        {
            Name "step"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Step.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
                //       let uv = pos.xy / texSize;
                // Divide by INPUT TEXTURE's own dimensions, not fullResolution.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                float4 color = inputTex.Sample(sampler_inputTex, uv);
                return nm_step(color);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
