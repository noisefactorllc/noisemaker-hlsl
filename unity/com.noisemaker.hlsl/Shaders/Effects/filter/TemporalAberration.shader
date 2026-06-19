Shader "Noisemaker/filter/temporalAberration"
{
    // filter/temporalAberration — temporal chromatic aberration via an 8-stage
    // RGBA "bucket-brigade" delay line. 9 passes in definition order: one "main"
    // read pass (program temporalAberration) that samples the live frame + the
    // eight persistent history stages _h1.._h8, then eight tail-first "shiftN"
    // copy passes (program delayShift) that advance the delay line by one frame.
    // The runtime drives the passes in order, rebinds srcTex per shift pass, and
    // keeps _h1.._h8 alive across frames (persistent state). All passes are plain
    // fullscreen blits with Blend Off (no additive accumulation). Inspector-only
    // Properties; the runtime binds the uniforms (redDelay/greenDelay/blueDelay)
    // and the per-pass input samplers via MaterialPropertyBlock.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "temporalAberration" (definition.js passes[0].program) — read pass
        Pass
        {
            Name "main"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_temporalAberration
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "TemporalAberration.hlsl"
            ENDHLSL
        }

        // progName "delayShift" (definition.js passes[1].program) — shift8: _h7 -> _h8
        Pass
        {
            Name "shift8"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_delayShift
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "TemporalAberration.hlsl"
            ENDHLSL
        }

        // delayShift — shift7: _h6 -> _h7
        Pass
        {
            Name "shift7"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_delayShift
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "TemporalAberration.hlsl"
            ENDHLSL
        }

        // delayShift — shift6: _h5 -> _h6
        Pass
        {
            Name "shift6"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_delayShift
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "TemporalAberration.hlsl"
            ENDHLSL
        }

        // delayShift — shift5: _h4 -> _h5
        Pass
        {
            Name "shift5"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_delayShift
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "TemporalAberration.hlsl"
            ENDHLSL
        }

        // delayShift — shift4: _h3 -> _h4
        Pass
        {
            Name "shift4"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_delayShift
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "TemporalAberration.hlsl"
            ENDHLSL
        }

        // delayShift — shift3: _h2 -> _h3
        Pass
        {
            Name "shift3"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_delayShift
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "TemporalAberration.hlsl"
            ENDHLSL
        }

        // delayShift — shift2: _h1 -> _h2
        Pass
        {
            Name "shift2"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_delayShift
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "TemporalAberration.hlsl"
            ENDHLSL
        }

        // delayShift — shift1: inputTex -> _h1
        Pass
        {
            Name "shift1"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_delayShift
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "TemporalAberration.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
