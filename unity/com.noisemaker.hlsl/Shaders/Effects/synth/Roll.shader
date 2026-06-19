Shader "Noisemaker/synth/roll"
{
    // synth/roll — MIDI piano roll visualizer. MULTI-PASS + FEEDBACK.
    // Pass "scroll" (program "roll"): reads the persistent feedback target
    // _rollFb (feedbackTex) and the engine MIDI note grid midiNoteGrid
    // (noteGridTex), scrolls the feedback right, writes new notes at the left
    // edge, draws lane separators -> outputTex. Pass "feedback" (program
    // "copy"): copies outputTex (inputTex) -> _rollFb so the next frame can
    // read it. The runtime drives passes in order and rebinds textures per pass
    // via MaterialPropertyBlock using the reference names (feedbackTex,
    // noteGridTex, inputTex, lineColor, gain, speed). Inspector-only Properties.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "roll" (definition.js passes[0].program; pass.name "scroll")
        Pass
        {
            Name "roll"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_roll
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Roll.hlsl"
            ENDHLSL
        }

        // progName "copy" (definition.js passes[1].program; pass.name "feedback")
        Pass
        {
            Name "copy"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_copy
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Roll.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
