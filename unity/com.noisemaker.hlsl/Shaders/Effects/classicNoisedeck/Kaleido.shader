Shader "Noisemaker/classicNoisedeck/kaleido"
{
    // classicNoisedeck/kaleido — kaleidoscopic mirrored-wedge sampling of the
    // input feed with an animated radial "offset" loop and an optional
    // convolution/pixellate/posterize kernel. Single render pass (program
    // "kaleido"). The runtime binds inputTex + all uniforms via
    // MaterialPropertyBlock using the reference uniform names. METRIC,
    // LOOP_OFFSET, DIRECTION and KERNEL are compile-time defines in the
    // reference; here they are int uniforms branched at runtime.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "kaleido" (definition.js passes[0].program)
        Pass
        {
            Name "kaleido"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_kaleido
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Kaleido.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
