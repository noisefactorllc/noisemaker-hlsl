Shader "Noisemaker/mixer/patternMix"
{
    // mixer/patternMix — mix two inputs (colorA = inputTex, colorB = tex) using a
    // geometric pattern mask. Single render pass (definition.js passes[0].program
    // "patternMix"). Properties are for the inspector only; the runtime binds params
    // via MaterialPropertyBlock by their reference uniform names.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "patternMix" (definition.js passes[0].program)
        Pass
        {
            Name "patternMix"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "PatternMix.hlsl"

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let dims = vec2<f32>(textureDimensions(inputTex, 0));
                //   let st   = position.xy / dims;
                //   colorA = textureSample(inputTex, samp, st);
                //   colorB = textureSample(tex,      samp, st);
                // position.xy is top-left, +0.5. NM_FragCoord(i) is the HLSL analog.
                // The SAME st (derived from inputTex's own size) samples BOTH textures.
                // tileOffset is NOT added (the WGSL does not add it).
                uint dw, dh;
                inputTex.GetDimensions(dw, dh);
                float2 dims = float2(dw, dh);
                float2 st = NM_FragCoord(i) / dims;

                float4 colorA = inputTex.Sample(sampler_inputTex, st);
                float4 colorB = tex.Sample(sampler_tex, st);

                return nm_patternMix(colorA, colorB, NM_FragCoord(i), dims);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
