Shader "Noisemaker/classicNoisedeck/shapes3d"
{
    // classicNoisedeck/shapes3d — raymarched 3D SDF primitives.
    // Single render pass. filter: samples inputTex for triplanar projection.
    // SHAPE_A, SHAPE_B, BLEND_MODE are int uniforms (compile-time defines in WGSL).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "shapes3d" (definition.js passes[0].program)
        Pass
        {
            Name "shapes3d"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_shapes3d
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Shapes3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
