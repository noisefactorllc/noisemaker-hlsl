Shader "Noisemaker/points/physical"
{
    // points/physical — physics-based particle simulation (gravity, wind, drag,
    // wander). COMMON-AGENT-ARCHITECTURE MIDDLEWARE. 2 passes per frame in
    // definition order: agent, passthrough.
    //
    //  Pass "agent" (MRT, drawBuffers:3): renders fullscreen across the agent
    //    STATE texture; reads the persistent 'global_'-prefixed state textures
    //    (global_xyz/global_vel/global_rgba, all rgba32f) and writes the three
    //    updated state textures via MRT (SV_Target0/1/2 = xyz/vel/rgba). The
    //    runtime ping-pongs each global state surface across frames (ref 04
    //    §10.7 isStateSurface matches the _xyz/_vel/_rgba suffix -> persist, no
    //    end-of-frame swap). There is NO drawMode "points" deposit pass and NO
    //    diffuse/trail pass in this effect -- those live in pointsRender;
    //    allocation + respawn live in pointsEmit.
    //  Pass "passthrough": fullscreen blit of inputTex -> outputTex for 2D-chain
    //    continuity.
    //
    // The runtime rebinds each pass's input/output textures and sets named
    // uniforms (and the inputTex sampler) via MaterialPropertyBlock by reference
    // names. The agent body never reads `resolution`, so the agent target being
    // the smaller stateSize texture is irrelevant to parity here.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "agent" (passes[0]) — MRT agent state update.
        // Fullscreen vertex; fragment returns SV_Target0/1/2 (xyz/vel/rgba).
        Pass
        {
            Name "agent"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_agent
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Physical.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[1]) — fullscreen blit input -> output.
        Pass
        {
            Name "passthrough"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_passthrough
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Physical.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
