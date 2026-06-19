Shader "Noisemaker/render/loopBegin"
{
    // render/loopBegin — start of an accumulator feedback loop. ONE pass:
    // "loopBegin" (passes[0]) reads the persistent feedback surface global_accum
    // and lighten-blends (component-wise max) it with the current chain input,
    // mixing by alpha and scaling the accumulator by intensity. The result is
    // passed through as outputTex; a matching render/loopEnd writes the processed
    // chain result back into global_accum to close the loop (reference 10).
    //
    // This is a plain fullscreen blend (NOT a 3D/geometry/raymarch pass). The
    // loop control-flow is handled by the frontend compiler + runtime, not this
    // shader. The runtime binds inputTex + the persistent global_accum surface
    // (as accumTex) and sets the named uniforms via MaterialPropertyBlock.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "loopBegin" (passes[0]) — feedback read + lighten blend
        Pass
        {
            Name "loopBegin"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_loopBegin
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "LoopBegin.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
