Shader "Noisemaker/filter/motionBlur"
{
    // filter/motionBlur — simple motion blur via frame blending with a PERSISTENT
    // feedback buffer. The runtime drives two passes in order each frame:
    //   "main"     (program motionBlur): blends inputTex with the previous frame
    //              held in _selfTex, writing outputTex.
    //   "feedback" (program copy): copies outputTex back into the persistent
    //              _selfTex so the next frame's "main" pass reads it.
    // _selfTex MUST persist across frames (state texture); the runtime binds the
    // textures and uniforms (amount, resetState) via MaterialPropertyBlock using
    // the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "motionBlur" (definition.js passes[0].program) — main blend pass.
        // blend not set in definition.js -> Blend Off.
        Pass
        {
            Name "motionBlur"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_motionBlur
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "MotionBlur.hlsl"
            ENDHLSL
        }

        // progName "copy" (definition.js passes[1].program) — feedback copy pass.
        // blend not set in definition.js -> Blend Off.
        Pass
        {
            Name "copy"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_copy
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "MotionBlur.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
