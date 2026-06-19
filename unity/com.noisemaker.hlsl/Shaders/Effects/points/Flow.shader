Shader "Noisemaker/points/flow"
{
    // points/flow — agent-based luminosity flow field (COMMON-AGENT-ARCHITECTURE
    // MIDDLEWARE). 2 passes per frame in definition order: agent, passthrough.
    //
    //  Pass "agent" (MRT, drawBuffers:3): renders fullscreen across the agent
    //    STATE texture; reads the persistent 'global_'-prefixed state textures
    //    (global_xyz/global_vel/global_rgba, all rgba32f) and writes the three
    //    updated state textures via MRT (SV_Target0/1/2). The runtime ping-pongs
    //    each global state surface across frames (ref 04 §10.7 isStateSurface).
    //    There is NO drawMode "points" deposit pass in this effect -- the deposit
    //    / trail / diffuse passes live in pointsRender; allocation in pointsEmit.
    //  Pass "passthrough": fullscreen blit of inputTex -> outputTex for 2D-chain
    //    continuity.
    //
    // The runtime rebinds each pass's input/output textures and sets named
    // uniforms (and the inputTex sampler) via MaterialPropertyBlock by reference
    // names. `resolution` stays at the SCREEN size for both passes even though the
    // agent target is the smaller stateSize texture (ref 04 §10.1).


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
            #include "Flow.hlsl"
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
            #include "Flow.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
