Shader "Noisemaker/filter/pixelSort"
{
    // filter/pixelSort — multi-pass GPGPU pixel-sorting glitch (6 passes).
    // The runtime drives each pass into its own intermediate RGBA-half texture
    // (definition.js textures{}), binding inputs/uniforms via MaterialPropertyBlock
    // by the reference uniform names. Properties below are inspector-only.
    //  Pass order: prepare -> luminance -> findBrightest -> computeRank ->
    //              gatherSorted -> finalize(outputTex).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // ---- Pass 1: prepare (program "prepare") ----------------------------
        Pass
        {
            Name "prepare"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_prepare
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "PixelSort.hlsl"
            ENDHLSL
        }

        // ---- Pass 2: luminance (program "luminance") ------------------------
        Pass
        {
            Name "luminance"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_luminance
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PixelSort.hlsl"
            ENDHLSL
        }

        // ---- Pass 3: findBrightest (program "findBrightest") ----------------
        Pass
        {
            Name "findBrightest"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_findBrightest
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PixelSort.hlsl"
            ENDHLSL
        }

        // ---- Pass 4: computeRank (program "computeRank") --------------------
        Pass
        {
            Name "computeRank"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_computeRank
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PixelSort.hlsl"
            ENDHLSL
        }

        // ---- Pass 5: gatherSorted (program "gatherSorted") ------------------
        Pass
        {
            Name "gatherSorted"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_gatherSorted
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PixelSort.hlsl"
            ENDHLSL
        }

        // ---- Pass 6: finalize (program "finalize") --------------------------
        Pass
        {
            Name "finalize"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_finalize
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PixelSort.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
