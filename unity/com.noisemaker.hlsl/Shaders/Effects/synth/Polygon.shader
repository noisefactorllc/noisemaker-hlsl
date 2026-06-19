Shader "Noisemaker/synth/polygon"
{
    // synth/polygon — regular polygon shape generator. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Polygon.hlsl (sides, radius, smoothing, rotation, fgColor, fgAlpha,
    // bgColor, bgAlpha). The Properties block is for inspector convenience only.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "shape" (definition.js passes[0].program)
        Pass
        {
            Name "shape"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles
            #include "Polygon.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                // WGSL divides st by resolution (not fullResolution).
                // aspectRatio = fullResolution.x / fullResolution.y (NMFullscreen alias).
                return nm_polygon(globalCoord, resolution, aspectRatio);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
