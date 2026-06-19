Shader "Noisemaker/classicNoisedeck/caustic"
{
    // classicNoisedeck/caustic — dual-noise caustic pattern with reflect blend.
    // Single render pass (generator, no inputs). Runtime binds params via
    // MaterialPropertyBlock by the names declared in Caustic.hlsl (noiseScale,
    // speed, wrap, seed, hueRotation, hueRange, intensity, NOISE_TYPE).
    // The Properties block is for inspector convenience only.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "caustic" (definition.js passes[0].program)
        Pass
        {
            Name "caustic"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "Caustic.hlsl"

            // No texture inputs (generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_caustic(globalCoord, fullResolution);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
