Shader "Noisemaker/synth/cell"
{
    // synth/cell — Worley/Voronoi distance-field generator. Single render pass.
    // No texture inputs (pure synth generator). Output: mono RGBA distance field.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Cell.hlsl (metric, scale, cellScale, cellSmooth, variation, speed, seed).
    // The Properties block below is for inspector convenience only.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "cell" (definition.js passes[0].program)
        Pass
        {
            Name "cell"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "Cell.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // st = (fragCoord + tileOffset) / fullResolution.y  (H13: HEIGHT).
                float2 st     = NM_GlobalCoord(i) / _NM_FullResolution.y;
                float  aspect = _NM_FullResolution.x / _NM_FullResolution.y;

                return nm_cell(st, scale, cellScale, metric, seed,
                               speed, variation, cellSmooth, time, aspect);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
