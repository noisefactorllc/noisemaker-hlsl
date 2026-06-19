Shader "Noisemaker/filter/reindex"
{
    // filter/reindex — three-pass palette reindex.
    //   stats  (nmReindexStats) : inputTex -> statsTiles (transient, screen-sized)
    //   reduce (nmReindexReduce): statsTiles -> global_stats (PERSISTENT 1x1 global)
    //   apply  (nmReindexApply) : inputTex + global_stats -> outputTex
    // The runtime drives the three passes in order and rebinds the integer-fetch
    // textures per pass (inputTex / statsTex map to the reference texture keys).
    // No blend; each pass fully overwrites its target. Inspector-only Properties;
    // the runtime binds the named uniform (uDisplacement) via MaterialPropertyBlock.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "nmReindexStats" (definition.js passes[0].program) — per-tile stats
        Pass
        {
            Name "nmReindexStats"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_nmReindexStats
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Reindex.hlsl"
            ENDHLSL
        }

        // progName "nmReindexReduce" (definition.js passes[1].program) — global reduce
        Pass
        {
            Name "nmReindexReduce"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_nmReindexReduce
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Reindex.hlsl"
            ENDHLSL
        }

        // progName "nmReindexApply" (definition.js passes[2].program) — remap/gather
        Pass
        {
            Name "nmReindexApply"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_nmReindexApply
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Reindex.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
