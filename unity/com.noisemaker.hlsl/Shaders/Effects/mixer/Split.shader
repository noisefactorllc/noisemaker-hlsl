Shader "Noisemaker/mixer/split"
{
    // mixer/split — wipe/split between two inputs (inputTex = A, tex = B) along
    // a rotatable, optionally animated line with adjustable softness.
    // Single render pass. Properties are for the inspector only; the runtime binds
    // params via MaterialPropertyBlock and the two input surfaces to inputTex / tex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "split" (definition.js passes[0].program)
        Pass
        {
            Name "split"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Split.hlsl"

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, linear
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let dims = vec2<f32>(textureDimensions(inputTex, 0));
                //   let st   = pos.xy / dims;
                //   colorA = textureSample(inputTex, samp, st);
                //   colorB = textureSample(tex,      samp, st);
                // The SAME st (derived from inputTex's own size) samples BOTH
                // textures. tileOffset is NOT added to the sample uv (WGSL does
                // not add it here). NM_FragCoord(i) is the HLSL pos.xy analog.
                uint dw, dh;
                inputTex.GetDimensions(dw, dh);
                float2 dims = float2(dw, dh);
                float2 st = NM_FragCoord(i) / dims;

                float4 colorA = inputTex.Sample(sampler_inputTex, st);
                float4 colorB = tex.Sample(sampler_tex, st);

                return nm_split(colorA, colorB, NM_FragCoord(i));
            }
            ENDHLSL
        }
    }
    Fallback Off
}
