Shader "Noisemaker/filter/octaveWarp"
{
    // filter/octaveWarp — per-octave noise warp distortion. Single render pass.
    // Optional 4-tap antialiasing. Inspector-only Properties; the runtime binds
    // these (and the inputTex sampler) via MaterialPropertyBlock using the
    // reference uniform names (frequency, octaves, displacement, speed, seed,
    // wrap, antialias).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "octaveWarp" (definition.js passes[0].program)
        Pass
        {
            Name "octaveWarp"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_octaveWarp
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "OctaveWarp.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
