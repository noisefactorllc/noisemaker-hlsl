Shader "Noisemaker/synth/mnca"
{
    // synth/mnca — Multi-neighbourhood cellular automata (multi-pass + feedback).
    // Pass "update" (program mncaFb) evolves the persistent global state buffer
    // (global_mnca_state) by sampling two concentric neighbourhoods; it reads the
    // global as bufTex (self-feedback) and the seed input as seedTex, writing the
    // next state back into global_mnca_state. Pass "render" (program mnca) reads
    // global_mnca_state as fbTex and upsamples it to the output via the selected
    // reconstruction filter. The runtime drives pass order and ping-pongs the
    // global state buffer; it binds the named uniforms + samplers via
    // MaterialPropertyBlock using the reference uniform names. Inspector-only
    // Properties.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "mncaFb" (definition.js passes[0] "update") — feedback/evolve.
        Pass
        {
            Name "mncaFb"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_mncaFb
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Mnca.hlsl"
            ENDHLSL
        }

        // progName "mnca" (definition.js passes[1] "render") — display/upsample.
        Pass
        {
            Name "mnca"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_mnca
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Mnca.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
