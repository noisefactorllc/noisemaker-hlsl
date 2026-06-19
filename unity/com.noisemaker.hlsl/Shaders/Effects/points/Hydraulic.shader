Shader "Noisemaker/points/hydraulic"
{
    // points/hydraulic — hydraulic-erosion flow agent (gradient descent).
    // Common Agent Architecture middleware. 2 passes per frame in definition
    // order: agent, passthrough.
    //
    // PASS 1 "agent" (MRT, drawBuffers:3): fullscreen over the AGENT STATE
    // texture (one texel == one agent). Reads the SHARED persistent state
    // surfaces global_xyz / global_vel / global_rgba (rgba32f, owned & seeded
    // by pointsEmit upstream) + inputTex, applies gradient descent on
    // inputTex's oklab-L luminance, and writes NEW state to all three via
    // MRT (outXYZ→SV_Target0, outVel→SV_Target1, outRGBA→SV_Target2). Inputs
    // and outputs are the SAME global_ keys; the runtime ping-pongs each per
    // write and the state PERSISTS frame-to-frame (isStateSurface suffix
    // _xyz/_vel/_rgba). No blend (full MRT replace).
    //
    // PASS 2 "passthrough" (fullscreen): copies inputTex to outputTex for 2D
    // chain continuity. No state touched.
    //
    // NO DEPOSIT/SCATTER PASS: hydraulic is an agent-UPDATE middleware. The
    // drawMode:"points" deposit lives in the separate pointsRender effect, so
    // both passes here are plain fullscreen (NMVertFullscreen) — no custom
    // SV_VertexID scatter vertex.
    //
    // The runtime rebinds each pass's input/output (and MRT) targets and sets
    // the named uniforms (and the inputTex sampler) via MaterialPropertyBlock
    // by their reference names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "agent" (passes[0]) — gradient-descent agent update (MRT 3)
        Pass
        {
            Name "agent"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_agent
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Hydraulic.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[1]) — copy inputTex to output
        Pass
        {
            Name "passthrough"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_passthrough
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Hydraulic.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
