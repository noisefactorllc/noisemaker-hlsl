Shader "Noisemaker/synth/sacredGeometry"
{
    // synth/sacredGeometry — flower-of-life and related sacred-geometry lattices.
    // Single render pass. Generator (no texture inputs).
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // SacredGeometry.hlsl (geometry, scale, rings, starPoints, rotation,
    // thickness, smoothness, fgColor, bgColor, animation, speed, pulseDepth).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // program "sacredGeometry" (definition.js passes[0].program)
        Pass
        {
            Name "sacredGeometry"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "SacredGeometry.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_sacredGeometry(globalCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
