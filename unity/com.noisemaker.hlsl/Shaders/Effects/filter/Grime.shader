Shader "Noisemaker/filter/grime"
{
    // filter/grime — dusty speckles and grime overlay. Multi-octave self-
    // refracted value noise, Chebyshev derivative, dropout specks, and sparse
    // exponential noise blended to dirty the input. Single render pass. RGB is
    // affected; alpha is passed through. Inspector-only Properties. The runtime
    // binds these (and the inputTex sampler) via MaterialPropertyBlock using the
    // reference uniform names (strength, seed).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "grime" (definition.js passes[0].program)
        Pass
        {
            Name "grime"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_grime
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Grime.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
