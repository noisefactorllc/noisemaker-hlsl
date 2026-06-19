Shader "Noisemaker/synth/reactionDiffusion"
{
    // synth/reactionDiffusion — Gray-Scott reaction-diffusion. MULTI-PASS with a
    // PERSISTENT FEEDBACK state texture (global_rd_state):
    //   Pass "simulate" (program rdFb): runs the Gray-Scott update on the low-res
    //     persistent state texture. It samples its own previous output
    //     (bufTex == global_rd_state) and writes back to global_rd_state.
    //     repeat:"iterations" — the runtime ping-pongs the global surface per
    //     iteration so each iteration reads the prior write.
    //   Pass "render" (program rd): formats the state (.g channel) into grayscale
    //     output into outputTex, with smoothing modes + optional input blend.
    // The C# runtime drives both passes in order, rebinds inputs per pass, and
    // manages the global_rd_state double buffer. Inspector-only Properties; the
    // runtime binds uniforms + samplers via MaterialPropertyBlock by reference
    // uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "rdFb" (definition.js passes[0]="simulate") — Gray-Scott update.
        // Pass Name MUST equal progName: NMShaderRegistry.ResolvePassIndex resolves
        // via Material.FindPass(progName), so the SubShader Pass is named "rdFb".
        Pass
        {
            Name "rdFb"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_rdFb
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ReactionDiffusion.hlsl"
            ENDHLSL
        }

        // progName "rd" (definition.js passes[1]="render") — display/format pass.
        // Pass Name MUST equal progName (FindPass(progName)); named "rd", not "render".
        Pass
        {
            Name "rd"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_rd
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ReactionDiffusion.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
