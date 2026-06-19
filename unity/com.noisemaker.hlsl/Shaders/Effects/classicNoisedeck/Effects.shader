Shader "Noisemaker/classicNoisedeck/effects"
{
    // classicNoisedeck/effects — multi-effect processor. Single render pass that
    // zooms/rotates/offsets/flips the sampling UV, optionally applies one of ~20
    // leaf effects (selected by EFFECT), then brightness/contrast + saturation.
    // EFFECT and FLIP are reference compile-time defines; here they are int
    // uniforms branched at runtime (PORTING-GUIDE §"Uniform binding model").
    // Inspector-only Properties; the runtime binds these (and the inputTex
    // sampler) via MaterialPropertyBlock using the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "effects" (definition.js passes[0].program)
        Pass
        {
            Name "effects"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_effects
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Effects.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
