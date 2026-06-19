Shader "Noisemaker/filter/tile"
{
    // filter/tile — symmetry-based kaleidoscope tiler (mirrorXY / rotate2 / rotate4 / rotate6).
    // Single render pass (program: "tile"). Sampler must be bilinear, clamp-to-edge,
    // non-sRGB to match the WebGL2/WebGPU path (H7).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "tile" (definition.js passes[0].program)
        Pass
        {
            Name "tile"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Tile.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, non-sRGB (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: texSize = vec2<f32>(textureDimensions(inputTex))
                //        uv     = position.xy / texSize
                // position.xy analog is NM_FragCoord(i) — top-left, +0.5 centered.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2((float)tw, (float)th);

                return nm_tile_frag(inputTex, sampler_inputTex, NM_FragCoord(i), texSize);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
