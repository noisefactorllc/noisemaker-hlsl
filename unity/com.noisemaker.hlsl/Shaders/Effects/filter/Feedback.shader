Shader "Noisemaker/filter/feedback"
{
    // filter/feedback — multi-pass feedback loop. The "main" pass (program
    // "feedback") blends the live inputTex with the persistent feedback buffer
    // _selfTex (sampled as selfTex) using blendMode/transform/lens/refract/color
    // controls, writing outputTex. The "feedback" pass (program "copy") snapshots
    // outputTex back into the persistent _selfTex for the next frame. The runtime
    // drives both passes in definition order and owns _selfTex persistence /
    // ping-pong (reference 04 §10.7 — _selfTex is a state surface, not swapped).
    // Inspector-only Properties; the runtime binds these (and the inputTex/selfTex
    // samplers) via MaterialPropertyBlock using the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "feedback" (definition.js passes[0].program; pass name "main")
        // inputTex + selfTex (_selfTex) -> outputTex
        Pass
        {
            Name "feedback"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_feedback
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Feedback.hlsl"
            ENDHLSL
        }

        // progName "copy" (definition.js passes[1].program; pass name "feedback")
        // outputTex (bound as inputTex) -> _selfTex
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
            #include "Feedback.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
