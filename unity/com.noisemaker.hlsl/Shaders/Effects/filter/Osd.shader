Shader "Noisemaker/filter/osd"
{
    // filter/osd — on-screen-display overlay: bank_ocr pseudo-glyph readout in a
    // corner, scanline tint, dark background panel, time-cycling digits.
    // Single render pass (the canonical WGSL is a per-pixel compute filter; we
    // emit it as one fullscreen pass). The runtime binds the input surface to
    // inputTex via MaterialPropertyBlock and sets alpha/seed/speed/corner.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "osd" (definition.js passes[0].program)
        Pass
        {
            Name "osd"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Osd.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: coord = vec2<i32>(gid.xy); texel = textureLoad(inputTex, coord, 0).
                // NM_FragCoord(i) is the top-left, +0.5-centered pixel coord; its
                // floor is the integer texel index (== gid.xy). w/h come from the
                // input texture's own dimensions (== WGSL params.width/height).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                int w = max((int)tw, 1);
                int h = max((int)th, 1);

                float2 fc = NM_FragCoord(i);
                int2 icoord = int2((int)floor(fc.x), (int)floor(fc.y));

                // Sample the exact texel (pixel-centered uv; linear+clamp -> texel).
                float2 uv = fc / float2((float)tw, (float)th);
                float4 texel = inputTex.Sample(sampler_inputTex, uv);

                return nm_osd(texel, icoord, w, h);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
