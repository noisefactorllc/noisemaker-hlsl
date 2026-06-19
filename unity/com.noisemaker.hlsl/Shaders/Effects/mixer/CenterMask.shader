Shader "Noisemaker/mixer/centerMask"
{
    // mixer/centerMask — blend from edges (inputTex/A) into center (tex/B) using
    // a distance-based mask with selectable shape, hardness, power, and blend mode.
    // Single render pass. The runtime binds params via MaterialPropertyBlock using
    // the uniform names from definition.js globals[*].uniform.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "centerMask" (definition.js passes[0].program)
        Pass
        {
            Name "centerMask"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "CenterMask.hlsl"

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA pipeline (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let dims = vec2<f32>(textureDimensions(inputTex, 0));
                //   let st   = position.xy / dims;
                //   edgeColor   = textureSample(inputTex, samp, st);
                //   centerColor = textureSample(tex,      samp, st);
                // pos = @builtin(position) (top-left, +0.5); NM_FragCoord(i) is
                // the HLSL analog. Both textures sampled at the same st (derived
                // from inputTex's own dimensions). tileOffset NOT added.
                uint dw, dh;
                inputTex.GetDimensions(dw, dh);
                float2 dims = float2(dw, dh);
                float2 st   = NM_FragCoord(i) / dims;

                float4 edgeColor   = inputTex.Sample(sampler_inputTex, st);
                float4 centerColor = tex.Sample(sampler_tex, st);

                float2 pos = NM_FragCoord(i);
                return nm_centerMask(edgeColor, centerColor, pos, dims);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
