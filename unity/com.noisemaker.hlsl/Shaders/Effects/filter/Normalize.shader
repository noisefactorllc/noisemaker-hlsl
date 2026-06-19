Shader "Noisemaker/filter/normalize"
{
    // filter/normalize — multi-pass GPGPU value normalization. Four passes form a
    // reduction pyramid that computes the global RGB min/max, then a final pass
    // rescales every pixel into [0,1]. The runtime drives each pass into its own
    // render target (see Effects/filter/normalize.json) and binds the inputs by
    // their reference names to inputTex / statsTex.
    //
    // No per-effect parameters (definition.js globals: {}).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass 1 — progName "reduce" (definition.js passes[0].program).
        // 16:1 pyramid reduction of the source image: per 16x16 block, .r=min RGB,
        // .g=max RGB. Uses integer texel fetch (.Load), no sampling.
        Pass
        {
            Name "reduce"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment fragReduce
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Normalize.hlsl"

            // Source surface. Read via integer texel fetch (.Load); no sampler used.
            Texture2D inputTex;

            float4 fragReduce(NMVaryings i) : SV_Target
            {
                // WGSL: let outCoord = vec2<i32>(input.position.xy);
                int2 outCoord = (int2)NM_FragCoord(i);

                // WGSL: let inSize = vec2<i32>(textureDimensions(inputTex));
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                int2 inSize = int2((int)tw, (int)th);

                // Each output pixel covers a 16x16 area of input.
                int2 baseCoord = outCoord * 16;

                float minVal = 100000.0;
                float maxVal = -100000.0;

                // Sample 16x16 block.
                for (int dy = 0; dy < 16; dy = dy + 1)
                {
                    for (int dx = 0; dx < 16; dx = dx + 1)
                    {
                        int2 sampleCoord = baseCoord + int2(dx, dy);

                        // Skip if out of bounds.
                        if (sampleCoord.x >= inSize.x || sampleCoord.y >= inSize.y)
                        {
                            continue;
                        }

                        float4 color = inputTex.Load(int3(sampleCoord, 0));

                        // Compute RGB min/max.
                        float pixelMin = min(min(color.r, color.g), color.b);
                        float pixelMax = max(max(color.r, color.g), color.b);

                        minVal = min(minVal, pixelMin);
                        maxVal = max(maxVal, pixelMax);
                    }
                }

                // Store min in r, max in g.
                return float4(minVal, maxVal, 0.0, 1.0);
            }
            ENDHLSL
        }

        // Pass 2 — progName "reduceMinmax" (definition.js passes[1].program).
        // 16:1 reduction of the min/max texture: input has min in .r, max in .g.
        Pass
        {
            Name "reduceMinmax"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment fragReduceMinmax
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Normalize.hlsl"

            Texture2D inputTex;

            float4 fragReduceMinmax(NMVaryings i) : SV_Target
            {
                // WGSL: let outCoord = vec2<i32>(input.position.xy);
                int2 outCoord = (int2)NM_FragCoord(i);

                // WGSL: let inSize = vec2<i32>(textureDimensions(inputTex));
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                int2 inSize = int2((int)tw, (int)th);

                // Each output pixel covers a 16x16 area of input.
                int2 baseCoord = outCoord * 16;

                float minVal = 100000.0;
                float maxVal = -100000.0;

                // Sample 16x16 block.
                for (int dy = 0; dy < 16; dy = dy + 1)
                {
                    for (int dx = 0; dx < 16; dx = dx + 1)
                    {
                        int2 sampleCoord = baseCoord + int2(dx, dy);

                        // Skip if out of bounds.
                        if (sampleCoord.x >= inSize.x || sampleCoord.y >= inSize.y)
                        {
                            continue;
                        }

                        float4 color = inputTex.Load(int3(sampleCoord, 0));

                        // Input has min in .r, max in .g.
                        minVal = min(minVal, color.r);
                        maxVal = max(maxVal, color.g);
                    }
                }

                return float4(minVal, maxVal, 0.0, 1.0);
            }
            ENDHLSL
        }

        // Pass 3 — progName "statsFinal" (definition.js passes[2].program).
        // Full scan of the (already-reduced) input down to a single 1x1 min/max.
        Pass
        {
            Name "statsFinal"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment fragStatsFinal
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Normalize.hlsl"

            Texture2D inputTex;

            float4 fragStatsFinal(NMVaryings i) : SV_Target
            {
                // WGSL: let inSize = vec2<i32>(textureDimensions(inputTex));
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                int2 inSize = int2((int)tw, (int)th);

                float minVal = 100000.0;
                float maxVal = -100000.0;

                // Scan entire texture.
                for (int y = 0; y < inSize.y; y = y + 1)
                {
                    for (int x = 0; x < inSize.x; x = x + 1)
                    {
                        float4 color = inputTex.Load(int3(x, y, 0));

                        // Input has min in .r, max in .g.
                        minVal = min(minVal, color.r);
                        maxVal = max(maxVal, color.g);
                    }
                }

                return float4(minVal, maxVal, 0.0, 1.0);
            }
            ENDHLSL
        }

        // Pass 4 — progName "apply" (definition.js passes[3].program).
        // Normalize each pixel using the 1x1 global stats (read at (0,0)).
        Pass
        {
            Name "apply"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment fragApply
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Normalize.hlsl"

            Texture2D inputTex;
            Texture2D statsTex;

            float4 fragApply(NMVaryings i) : SV_Target
            {
                // WGSL: let coord = vec2<i32>(input.position.xy);
                int2 coord = (int2)NM_FragCoord(i);

                // Read global min/max from the 1x1 stats texture.
                float4 stats = statsTex.Load(int3(0, 0, 0));
                float global_min = stats.r;
                float global_max = stats.g;
                float range = global_max - global_min;

                // Read input pixel.
                float4 texel = inputTex.Load(int3(coord, 0));

                // Normalize RGB channels, preserve alpha.
                // GLSL golden (apply.glsl:22) guards with `maxVal - minVal < 0.00001`
                // (1e-5), not the WGSL 1e-4; matches for near-flat inputs.
                float4 normalized;
                if (range > 0.00001)
                {
                    normalized = float4(
                        (texel.r - global_min) / range,
                        (texel.g - global_min) / range,
                        (texel.b - global_min) / range,
                        texel.a
                    );
                }
                else
                {
                    // Avoid division by zero.
                    normalized = texel;
                }

                return normalized;
            }
            ENDHLSL
        }
    }
    Fallback Off
}
