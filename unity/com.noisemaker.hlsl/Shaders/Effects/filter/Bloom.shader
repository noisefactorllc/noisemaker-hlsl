Shader "Noisemaker/filter/bloom"
{
    // filter/bloom — multi-pass bloom. The runtime drives three passes in order,
    // rebinding inputTex/bloomTex per pass:
    //   brightPass : inputTex            -> _brightTex
    //   ntapGather : _brightTex          -> _bloomTex   (rebound onto inputTex)
    //   composite  : inputTex + _bloomTex-> outputTex
    // Inspector-only Properties. The runtime binds these (and the texture
    // samplers) via MaterialPropertyBlock using the reference uniform names
    // (threshold, softKnee, radius, taps, intensity, tint).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "brightPass" (definition.js passes[0].program)
        Pass
        {
            Name "brightPass"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_brightPass
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Bloom.hlsl"
            ENDHLSL
        }

        // progName "ntapGather" (definition.js passes[1].program)
        Pass
        {
            Name "ntapGather"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_ntapGather
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Bloom.hlsl"
            ENDHLSL
        }

        // progName "composite" (definition.js passes[2].program)
        Pass
        {
            Name "composite"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_composite
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Bloom.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
