Shader "Noisemaker/synth/cellularAutomata"
{
    // synth/cellularAutomata — multi-pass FEEDBACK effect (func: "cellularAutomata").
    // Pass "update" (program caFb) advances the persistent CA grid surface
    // global_ca_state (reads its own previous state as bufTex => feedback) and
    // writes back into global_ca_state. Pass "render" (program ca) reconstructs
    // the grid into outputTex with the selected smoothing filter. The runtime
    // drives both passes in order and ping-pongs the persistent global_ca_state
    // surface (a state surface — never auto-swapped like a display surface).
    // Inspector-only Properties; the runtime binds uniforms + samplers via
    // MaterialPropertyBlock using the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "caFb" (definition.js passes[0].program) — CA update / feedback.
        // Output target: global_ca_state (persistent). Blend Off (no blend:true).
        Pass
        {
            Name "caFb"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_caFb
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "CellularAutomata.hlsl"
            ENDHLSL
        }

        // progName "ca" (definition.js passes[1].program) — display reconstruction.
        // Output target: outputTex. Blend Off (no blend:true).
        Pass
        {
            Name "ca"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_ca
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "CellularAutomata.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
