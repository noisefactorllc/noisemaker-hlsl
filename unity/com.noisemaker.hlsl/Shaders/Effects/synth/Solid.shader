Shader "Noisemaker/synth/solid"
{
    // No Properties block: the runtime binds all uniforms via MaterialPropertyBlock
    // by their HLSL name (color, alpha). A ShaderLab Properties block is unnecessary
    // here and would collide with reserved tokens (color -> TOK_COLOR).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        // synth/solid is a single render pass (program "solid").
        Pass
        {
            Name "solid"

            ZWrite Off
            ZTest Always
            Cull Off
            Blend Off

            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_solid
            #pragma target 4.5

            #include "Solid.hlsl"
            ENDHLSL
        }
    }
}
