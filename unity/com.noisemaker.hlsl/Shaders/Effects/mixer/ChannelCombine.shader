Shader "Noisemaker/mixer/channelCombine"
{
    // mixer/channelCombine — combine three surface inputs into R, G, B channels.
    // Each surface is converted to luminance and scaled by its level (0..100).
    // Single render pass. Properties are inspector-only; the runtime binds params
    // via MaterialPropertyBlock (rLevel / gLevel / bLevel) and binds the three
    // input surfaces to rTex / gTex / bTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "channelCombine" (definition.js passes[0].program)
        Pass
        {
            Name "channelCombine"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ChannelCombine.hlsl"

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    rTex;
            SamplerState sampler_rTex;
            Texture2D    gTex;
            SamplerState sampler_gTex;
            Texture2D    bTex;
            SamplerState sampler_bTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let st = position.xy / resolution;
                //   let r = luminance(textureSample(rTex, samp, st)) * rLevel / 100.0;
                //   let g = luminance(textureSample(gTex, samp, st)) * gLevel / 100.0;
                //   let b = luminance(textureSample(bTex, samp, st)) * bLevel / 100.0;
                //   return vec4<f32>(r, g, b, 1.0);
                //
                // WGSL resolution is the output/render target size. NMFullscreen
                // supplies the `resolution` alias (= _NM_Resolution.xy) for this. All
                // three textures share the same `st`. tileOffset is NOT added (the
                // WGSL does not add it).
                float2 st = NM_FragCoord(i) / resolution;

                float4 rSample = rTex.Sample(sampler_rTex, st);
                float4 gSample = gTex.Sample(sampler_gTex, st);
                float4 bSample = bTex.Sample(sampler_bTex, st);

                return nm_channelCombine(rSample, gSample, bSample);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
