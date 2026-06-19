Shader "Noisemaker/render/loopEnd"
{
    // render/loopEnd — end of an accumulator feedback loop. TWO passes, both
    // using the shared fullscreen "copy"/blit program (frag_copy):
    //   "feedback" (passes[0]) copies inputTex into the persistent global_accum
    //              feedback surface, writing back the processed chain result and
    //              closing the loop that render/loopBegin opens (reference 10).
    //   "output"   (passes[1]) copies the same inputTex to outputTex, passing the
    //              result through to the next effect in the chain.
    // Identical fragment program for both; only the runtime-bound output differs.
    //
    // This is a plain fullscreen copy (NOT a 3D/geometry/raymarch pass). The loop
    // control-flow is handled by the frontend compiler + runtime, not this shader.
    // The runtime binds inputTex and the persistent global_accum surface (the
    // feedback pass's render target) and drives the passes in order.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "copy" (passes[0] "feedback") — blit inputTex -> global_accum
        // (write the processed result back into the persistent feedback buffer).
        Pass
        {
            Name "feedback"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_copy
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "LoopEnd.hlsl"
            ENDHLSL
        }

        // progName "copy" (passes[1] "output") — blit inputTex -> outputTex
        // (pass the result through to the next effect). Same program as above.
        Pass
        {
            Name "output"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_copy
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "LoopEnd.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
