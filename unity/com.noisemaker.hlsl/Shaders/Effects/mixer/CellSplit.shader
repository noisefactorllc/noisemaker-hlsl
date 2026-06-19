Shader "Noisemaker/mixer/cellSplit"
{
    // mixer/cellSplit — split between two inputs (A = inputTex, B = tex) using
    // Voronoi cell regions. Single render pass. Properties are inspector-only; the
    // runtime binds params via MaterialPropertyBlock by their reference uniform
    // names (mode/scale/edgeWidth/seed/invert/speed) and binds the two input
    // surfaces to inputTex / tex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "cellSplit" (definition.js passes[0].program)
        Pass
        {
            Name "cellSplit"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "CellSplit.hlsl"

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // Color sample uv (WGSL lines 41-45): position.xy / inputTex's OWN
                // dimensions, used for BOTH inputTex and tex (no tileOffset added).
                // NM_FragCoord(i) is the top-left, +0.5-centered HLSL analog of
                // @builtin(position).xy.
                uint dw, dh;
                inputTex.GetDimensions(dw, dh);
                float2 dims = float2(dw, dh);
                float2 st = NM_FragCoord(i) / dims;

                float4 colorA = inputTex.Sample(sampler_inputTex, st);
                float4 colorB = tex.Sample(sampler_tex, st);

                // Voronoi uv (WGSL lines 49-52): aspect-correct, scaled coordinates
                // using FULL image dimensions so cells are consistent across tiles.
                //   let aspect    = fullResolution.x / fullResolution.y;
                //   let globalUV  = (position.xy + tileOffset) / fullResolution;
                //   var p = globalUV * (31.0 - scale);
                //   p.x = p.x * aspect;
                // NM_GlobalCoord(i) == position.xy + tileOffset.
                float aspect = fullResolution.x / fullResolution.y;
                float2 globalUV = NM_GlobalCoord(i) / fullResolution;
                float2 p = globalUV * (31.0 - scale);
                p.x = p.x * aspect;

                return nm_cellSplit(colorA, colorB, p);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
