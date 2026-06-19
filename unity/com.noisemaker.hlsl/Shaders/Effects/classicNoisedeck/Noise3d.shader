Shader "Noisemaker/classicNoisedeck/noise3d"
{
    // classicNoisedeck/noise3d — ray-marched 3D noise volumes. Single render
    // pass, no texture inputs (generator). Runtime binds params via
    // MaterialPropertyBlock by the names declared in Noise3d.hlsl (NOISE_TYPE,
    // ridges, seed, speed, scale, offsetX, offsetY, colorMode, hueRotation,
    // hueRange). The Properties block is for inspector convenience only.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "noise3d" (definition.js passes[0].program)
        Pass
        {
            Name "noise3d"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "Noise3d.hlsl"

            // No texture inputs (generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_noise3d(globalCoord, fullResolution, time);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
