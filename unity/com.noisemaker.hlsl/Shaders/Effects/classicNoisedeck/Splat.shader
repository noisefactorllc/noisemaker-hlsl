Shader "Noisemaker/classicNoisedeck/splat"
{
    // classicNoisedeck/splat — splatter paint compositor overlay.
    // Single-input FILTER, single render pass (program "splat").
    // Builds PCG/Perlin splat + speck masks and composites them over inputTex
    // in one of four modes each (0 color,1 displace,2 invert,3 negative).
    // Properties are inspector-only; the runtime binds these via
    // MaterialPropertyBlock by their reference uniform names and binds the input
    // surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "splat" (definition.js passes[0].program)
        Pass
        {
            Name "splat"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Splat.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL main():
                //   let dims = vec2<f32>(textureDimensions(inputTex, 0));
                //   let aspectRatio = dims.x / dims.y;
                //   var uv = fragCoord.xy / dims;
                // fragCoord = @builtin(position) (top-left, +0.5); NM_FragCoord(i)
                // is the HLSL analog. Divide by the INPUT TEXTURE's own size (not
                // fullResolution) — both uv AND aspectRatio use inputTex dims.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 dims = float2(tw, th);
                float aspectRatioLocal = dims.x / dims.y;
                float2 uv = NM_FragCoord(i) / dims;

                float4 color_ = inputTex.Sample(sampler_inputTex, uv);

                float2 noiseCoord = uv * float2(aspectRatioLocal, 1.0);

                if (useSpecks != 0)
                {
                    float speckMask = nm_splat_speckle(noiseCoord + speckSeed,
                        float2(32.0, 32.0) * nm_splat_mapRange(speckScale, 1.0, 5.0, 2.0, 0.5));

                    [branch]
                    if (speckMode == 0)
                    {
                        color_ = float4(lerp(color_.rgb, speckColor, speckMask), color_.a); // color
                    }
                    else if (speckMode == 1)
                    {
                        color_ = inputTex.Sample(sampler_inputTex, uv + speckMask * 0.1); // displace
                    }
                    else if (speckMode == 2)
                    {
                        color_ = float4(lerp(color_.rgb, 1.0 - color_.rgb, speckMask), color_.a); // invert
                    }
                    else if (speckMode == 3)
                    {
                        color_ = float4(color_.rgb * speckMask, color_.a); // negative
                    }
                }

                if (enabled != 0)
                {
                    float splatMask = nm_splat_splat(noiseCoord + seed,
                        float2(nm_splat_mapRange(scale, 1.0, 5.0, 2.0, 0.5),
                               nm_splat_mapRange(scale, 1.0, 5.0, 2.0, 0.5)));

                    [branch]
                    if (mode == 0)
                    {
                        color_ = float4(lerp(color_.rgb, color, splatMask), color_.a); // color
                    }
                    else if (mode == 1)
                    {
                        float4 texColor = inputTex.Sample(sampler_inputTex, uv + splatMask * 0.1); // displace
                        color_ = lerp(color_, texColor, splatMask);
                    }
                    else if (mode == 2)
                    {
                        color_ = float4(lerp(color_.rgb, 1.0 - color_.rgb, splatMask), color_.a); // invert
                    }
                    else if (mode == 3)
                    {
                        color_ = float4(color_.rgb * nm_splat_mapRange(splatMask * 0.5 - 0.5, -0.25, 0.0, 0.0, 1.0), color_.a); // negative
                    }
                }

                return color_;
            }
            ENDHLSL
        }
    }
    Fallback Off
}
