Shader "Noisemaker/filter/waves"
{
    // filter/waves — sine wave distortion with rotation, wrap modes, and RGSS antialias.
    // Single render pass. Input texture is sampled at the distorted UV.
    // Runtime binds all uniforms via MaterialPropertyBlock using the reference names
    // (strength, scale, speed, wrap, rotation, antialias).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "waves" (definition.js passes[0].program)
        Pass
        {
            Name "waves"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_waves
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Waves.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
