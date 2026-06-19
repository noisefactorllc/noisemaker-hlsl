Shader "Noisemaker/filter/tetraColorArray"
{
    // filter/tetraColorArray — discrete color gradient mapping based on luminance.
    // Supports 2-8 colors; blend spaces: RGB, HSV, OkLab, OKLCH.
    // Single render pass (definition.js passes[0].program = "tetraColorArray").
    // The runtime binds all uniforms via MaterialPropertyBlock using the exact
    // names from definition.js globals[*].uniform.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "tetraColorArray" (definition.js passes[0].program)
        Pass
        {
            Name "tetraColorArray"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "TetraColorArray.hlsl"

            // Input surface. Bilinear, clamp-to-edge, LINEAR (non-sRGB) sampler
            // to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let size = vec2<f32>(textureDimensions(inputTex, 0));
                //   let uv = position.xy / size;
                // Divide by the INPUT TEXTURE's own size, not fullResolution.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 size = float2((float)tw, (float)th);
                float2 uv = NM_FragCoord(i) / size;

                float4 inputColor = inputTex.Sample(sampler_inputTex, uv);
                return nm_tetraColorArray(inputColor, time);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
