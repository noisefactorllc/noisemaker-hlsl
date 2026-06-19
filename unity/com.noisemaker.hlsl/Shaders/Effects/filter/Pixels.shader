Shader "Noisemaker/filter/pixels"
{
    // filter/pixels — Pixelation (retro pixel art look).
    // Single render pass. Per-effect parameter: int size (block size in px).
    // Tile-aware: pixel grid snaps on global coordinates when tileOffset != (0,0).
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "pixels" (definition.js passes[0].program)
        Pass
        {
            Name "pixels"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Pixels.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
                //       let uv = pos.xy / texSize;
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 fragCoord = NM_FragCoord(i); // top-left +0.5 centered
                float2 uv = fragCoord / texSize;

                // WGSL: if (uniforms.size < 1.0) { return textureSample(..., uv); }
                float pixelSize = (float)size;
                if (pixelSize < 1.0)
                {
                    return inputTex.Sample(sampler_inputTex, uv);
                }

                // WGSL: let isTile = length(uniforms.tileOffset) > 0.0;
                bool isTile = length(tileOffset) > 0.0;

                if (isTile)
                {
                    // WGSL: let resolution = select(texSize, uniforms.fullResolution,
                    //                               uniforms.fullResolution.x > 0.0);
                    // WGSL select(false_val, true_val, cond) == HLSL (cond ? true_val : false_val)
                    float2 resolution = (fullResolution.x > 0.0) ? fullResolution : texSize;

                    float dx = pixelSize / resolution.x;
                    float dy = pixelSize / resolution.y;

                    // WGSL: let globalUV = (pos.xy + uniforms.tileOffset) / resolution;
                    float2 globalUV = (fragCoord + tileOffset) / resolution;
                    float2 centered = globalUV - 0.5;

                    // WGSL: var gcoord = vec2<f32>(dx * floor(centered.x / dx),
                    //                              dy * floor(centered.y / dy));
                    //       gcoord = gcoord + 0.5;
                    float2 gcoord = float2(dx * floor(centered.x / dx),
                                          dy * floor(centered.y / dy));
                    gcoord = gcoord + 0.5;

                    // WGSL: let coord = (gcoord * resolution - uniforms.tileOffset) / texSize;
                    float2 coord = (gcoord * resolution - tileOffset) / texSize;
                    return inputTex.Sample(sampler_inputTex, coord);
                }

                // Non-tiling path (byte-identical to the previous simple pixelation).
                // WGSL: let dx = pixelSize / texSize.x; dy = pixelSize / texSize.y;
                //       var centered = uv - 0.5;
                //       var coord = vec2<f32>(dx * floor(centered.x / dx),
                //                            dy * floor(centered.y / dy));
                //       coord = coord + 0.5;
                float dx = pixelSize / texSize.x;
                float dy = pixelSize / texSize.y;
                float2 centered = uv - 0.5;
                float2 coord = float2(dx * floor(centered.x / dx),
                                      dy * floor(centered.y / dy));
                coord = coord + 0.5;
                return inputTex.Sample(sampler_inputTex, coord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
