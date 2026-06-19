Shader "Noisemaker/points/lenia"
{
    // points/lenia — Particle Lenia artificial-life simulation. AGENT / MULTI-PASS
    // / MRT / POINTS-SCATTER / FEEDBACK. 5 passes per frame in definition order:
    //   clear (fullscreen), deposit (drawMode:points, additive), convolve
    //   (fullscreen), agentField (fullscreen, MRT x3), passthrough (fullscreen).
    // PERSISTENT 'global_' agent state (rgba32f, double-buffered, isStateSurface):
    //   global_xyz (x,y,z,alive), global_vel (vx,vy,age,seed), global_rgba (color).
    //   These survive frame-to-frame; agentField reads + rewrites all three via MRT
    //   (in-place feedback). Transient private state (rgba16f, 50% res, recomputed
    //   each frame): global_lenia_density (deposit accumulation),
    //   global_lenia_field (convolved U). The runtime rebinds each pass's
    //   input/output textures and sets named uniforms via MaterialPropertyBlock by
    //   reference names. The deposit pass is issued via DrawProcedural(Points, N)
    //   with N = stateSize*stateSize (one point per agent texel); its vertex stage
    //   reads xyzTex per SV_VertexID.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "clear" (passes[0]) — zero the density accumulation texture
        Pass
        {
            Name "clear"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_clear
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Lenia.hlsl"
            ENDHLSL
        }

        // progName "deposit" (passes[1]) — points-scatter agents into density
        // drawMode:"points"; additive accumulation into the float density texture.
        Pass
        {
            Name "deposit"
            Blend One One
            HLSLPROGRAM
            #pragma vertex vert_deposit
            #pragma fragment frag_deposit
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Lenia.hlsl"
            ENDHLSL
        }

        // progName "convolve" (passes[2]) — gaussian-shell kernel K(r) -> U field
        Pass
        {
            Name "convolve"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_convolve
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Lenia.hlsl"
            ENDHLSL
        }

        // progName "agentField" (passes[3]) — update agent state from field
        // MRT x3: SV_Target0=outXYZ, SV_Target1=outVel, SV_Target2=outRGBA.
        Pass
        {
            Name "agentField"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_agentField
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Lenia.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[4]) — copy inputTex -> outputTex
        Pass
        {
            Name "passthrough"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_passthrough
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Lenia.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
