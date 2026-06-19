Shader "Noisemaker/classicNoisedeck/cellRefract"
{
    // classicNoisedeck/cellRefract — cell-noise distance-field refraction of the
    // input feed with an optional convolution/pixellate/posterize kernel. Single
    // render pass (program "cellRefract"). The runtime binds inputTex + all
    // uniforms via MaterialPropertyBlock using the reference uniform names.
    // SHAPE and KERNEL are compile-time defines in the reference; here they are
    // int uniforms branched at runtime.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "cellRefract" (definition.js passes[0].program)
        Pass
        {
            Name "cellRefract"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_cellRefract
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "CellRefract.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
