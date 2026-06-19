Shader "Noisemaker/points/buddhabrot"
{
    // points/buddhabrot — Buddhabrot fractal via progressive orbit accumulation
    // (AGENT-UPDATE middleware of the Common Agent Architecture). 3 passes per
    // frame in definition order:
    //   agent        — orbit advance, MRT 3 outputs (global_xyz/vel/rgba)
    //   zWrite       — recompute z to current step → global_zState
    //   passthrough  — bilinear copy inputTex → outputTex
    //
    // PERSISTENT state textures global_xyz [screenX,screenY,phase,alive],
    // global_vel [c.re,c.im,step,escapeStep], global_rgba [b,b,b,1] are created
    // by the surrounding pointsEmit pipeline (rgba32f) and carry sim state
    // across frames. The runtime ping-pongs them per write and persists them
    // frame-to-frame via the isStateSurface predicate (xyz/vel/rgba qualify —
    // reference 04 §10.7). global_zState (rgba32f) is this effect's own
    // transient z-storage. The runtime rebinds each pass's input/output
    // textures and sets named uniforms via MaterialPropertyBlock by reference
    // name.
    //
    // NOTE: there is NO deposit/points-scatter pass here — the scatter
    // (drawMode:"points", additive Blend One One) lives in the separate
    // pointsEmit/pointsRender middleware. Every pass below is fullscreen
    // (NMVertFullscreen), Blend Off.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "agent" (passes[0]) — orbit advance, MRT 3 outputs
        Pass
        {
            Name "agent"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_agent
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Buddhabrot.hlsl"
            ENDHLSL
        }

        // progName "zWrite" (passes[1]) — recompute z → global_zState
        Pass
        {
            Name "zWrite"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_zWrite
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Buddhabrot.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[2]) — bilinear copy inputTex → outputTex
        Pass
        {
            Name "passthrough"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_passthrough
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Buddhabrot.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
