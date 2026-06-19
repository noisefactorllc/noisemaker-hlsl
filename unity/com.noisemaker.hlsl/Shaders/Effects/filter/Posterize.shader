Shader "Noisemaker/filter/posterize"
{
    // Inspector-only Properties. The runtime binds these (and the inputTex
    // sampler) via MaterialPropertyBlock using the reference uniform names
    // (levels, gamma, antialias).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        // filter/posterize is a single render pass (program "posterize").
        Pass
        {
            Name "posterize"

            ZWrite Off
            ZTest Always
            Cull Off
            Blend Off

            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_posterize
            #pragma target 4.5

            #include "Posterize.hlsl"
            ENDHLSL
        }
    }
}
