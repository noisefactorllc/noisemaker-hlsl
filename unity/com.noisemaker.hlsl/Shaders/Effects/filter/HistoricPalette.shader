Shader "Noisemaker/filter/historicPalette"
{
    // filter/historicPalette — maps luminance to historical art color palettes.
    // Single render pass. The runtime binds the input surface to inputTex and
    // all parameters via MaterialPropertyBlock using the uniform names from
    // definition.js globals[*].uniform.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "historicPalette" (definition.js passes[0].program)
        Pass
        {
            Name "historicPalette"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "HistoricPalette.hlsl"

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
                // the HLSL analog. Divide by the INPUT TEXTURE's own size, not
                // fullResolution.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                float4 inputColor = inputTex.Sample(sampler_inputTex, uv);
                return nm_historicPalette(inputColor);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
