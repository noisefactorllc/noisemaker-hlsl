Shader "Noisemaker/mixer/thresholdMix"
{
    // mixer/thresholdMix — combine two inputs using threshold masking with
    // optional posterization; supports luminance or per-channel RGB modes.
    // Single render pass. The runtime binds params via MaterialPropertyBlock
    // using the reference uniform names and binds surfaces to inputTex / tex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "thresholdMix" (definition.js passes[0].program)
        Pass
        {
            Name "thresholdMix"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ThresholdMix.hlsl"

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let dims = vec2f(textureDimensions(inputTex, 0));
                //   let uv   = position.xy / dims;
                //   let colorA = textureSample(inputTex, samp, uv);
                //   let colorB = textureSample(tex,      samp, uv);
                // pos = @builtin(position) (top-left, +0.5); NM_FragCoord(i) is
                // the HLSL analog. The SAME uv (from inputTex's dims) samples BOTH
                // textures. tileOffset is NOT added (the WGSL does not add it).
                uint dw, dh;
                inputTex.GetDimensions(dw, dh);
                float2 dims = float2(dw, dh);
                float2 uv = NM_FragCoord(i) / dims;

                float4 colorA = inputTex.Sample(sampler_inputTex, uv);
                float4 colorB = tex.Sample(sampler_tex, uv);

                return nm_thresholdMix(colorA, colorB);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
