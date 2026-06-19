Shader "Noisemaker/filter/polar"
{
    // filter/polar — polar and vortex coordinate transforms.
    // Single render pass (progName "polar", definition.js passes[0].program).
    // Inspector-only Properties. The runtime binds these via MaterialPropertyBlock
    // using the reference uniform names (polarMode, scale, rotation, speed,
    // aspectLens, antialias) and the inputTex sampler.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "polar" (definition.js passes[0].program)
        Pass
        {
            Name "polar"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_polar
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Polar.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
