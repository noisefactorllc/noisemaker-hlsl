Shader "Noisemaker/classicNoisedeck/cellNoise"
{
    // classicNoisedeck/cellNoise — Worley/cellular noise generator with an
    // OPTIONAL input surface `tex` (texInfluence). Single render pass, program
    // "cellNoise". The runtime binds all params and the `tex` sampler via
    // MaterialPropertyBlock using the reference uniform names declared in
    // CellNoise.hlsl. Properties below are inspector-only convenience.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "cellNoise" (definition.js passes[0].program)
        Pass
        {
            Name "cellNoise"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_cellNoise
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "CellNoise.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
