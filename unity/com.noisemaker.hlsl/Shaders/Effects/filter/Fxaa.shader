Shader "Noisemaker/filter/fxaa"
{
    // filter/fxaa — edge-aware luminance-weighted anti-aliasing.
    // Single render pass. Uniforms: strength, sharpness, threshold.
    // Input sampled via Texture2D.Load (integer pixel coords, no sampler needed —
    // mirrors the WGSL textureLoad path exactly).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "fxaa" (definition.js passes[0].program)
        Pass
        {
            Name "fxaa"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Fxaa.hlsl"

            // Input surface. No sampler required — all fetches use Texture2D.Load
            // (integer coords), matching the WGSL textureLoad path.
            // SamplerState declared for completeness / SG compatibility but unused
            // in the frag below. // TODO(verify): confirm Load path on all D3D11 drivers.
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let pixel_coord = vec2<i32>(i32(position.x), i32(position.y));
                // position.x/.y are top-left pixel-center (+0.5) coords.
                // NM_FragCoord(i) returns the same value. Truncate to integer = floor.
                float2 fc = NM_FragCoord(i);
                int2 pixel_coord = int2((int)fc.x, (int)fc.y);

                uint tw, th;
                inputTex.GetDimensions(tw, th);
                int2 sz = int2((int)tw, (int)th);

                return nm_fxaa_main(inputTex, pixel_coord, sz);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
