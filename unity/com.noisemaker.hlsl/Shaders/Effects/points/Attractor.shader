Shader "Noisemaker/points/attractor"
{
    // points/attractor — strange-attractor agent middleware. 2 passes per frame
    // in definition order: agent, passthrough.
    //
    // PASS 1 "agent": FULLSCREEN MRT state update (drawBuffers:3). Reads the
    // PERSISTENT shared state textures global_xyz/global_vel/global_rgba
    // (rgba32f) and writes new state via SV_Target0/1/2 (outXYZ/outVel/outRGBA).
    // The runtime ping-pongs each global per write/frame (reference 04
    // §10.2/§10.7; isStateSurface matches xyz/vel/rgba so they PERSIST). NOT a
    // points-scatter pass — the agent update is fullscreen over the state texel
    // grid. (Points-scatter / 1px deposit happens downstream in pointsRender.)
    //
    // PASS 2 "passthrough": FULLSCREEN copy of inputTex -> outputTex (2D chain
    // continuity; the 2D image is untouched by the agent sim).
    //
    // The runtime rebinds each pass's input/output textures and sets named
    // uniforms (and the inputTex sampler) via MaterialPropertyBlock by reference
    // names. Both passes are fullscreen (NMVertFullscreen); neither is additive
    // (Blend Off) since there is no deposit/scatter pass in this effect.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "agent" (passes[0]) — strange-attractor state update (MRT x3)
        Pass
        {
            Name "agent"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_agent
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Attractor.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[1]) — copy inputTex -> outputTex
        Pass
        {
            Name "passthrough"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_passthrough
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Attractor.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
