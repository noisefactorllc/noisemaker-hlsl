Shader "Noisemaker/filter/lensWarp"
{
    // filter/lensWarp — noise-driven radial lens distortion. Two Perlin fields
    // drive X/Y UV displacement, masked toward the frame edges by a pow(5)
    // aspect-correct radial singularity mask, mirror-wrapped, with optional 4-tap
    // antialiasing. Single render pass. The runtime binds these (and the inputTex
    // sampler) via MaterialPropertyBlock using the reference uniform names
    // (displacement, antialias). `speed` (oscillator speed) is engine-supplied.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "lensWarp" (definition.js passes[0].program)
        Pass
        {
            Name "lensWarp"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_lensWarp
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "LensWarp.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
