Shader "Noisemaker/classicNoisedeck/glitch"
{
    // classicNoisedeck/glitch — digital glitch processor. Deterministic noise
    // fields drive scanline shears, snow bursts, chromatic aberration, and
    // barrel/pincushion lensing. Single render pass. Inspector-only Properties;
    // the runtime binds these (and the inputTex sampler) via MaterialPropertyBlock
    // using the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "glitch" (definition.js passes[0].program)
        Pass
        {
            Name "glitch"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_glitch
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Glitch.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
