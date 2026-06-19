Shader "Noisemaker/points/flock"
{
    // points/flock — 2D "Boids" flocking agent simulation. Common Agent
    // Architecture middleware. 2 passes per frame in definition order:
    //   agent       — MRT state update (3 render targets: SV_Target0=xyz,
    //                  SV_Target1=vel, SV_Target2=rgba). Reads the three
    //                  PERSISTENT particle-state textures global_xyz [x,y,z,alive],
    //                  global_vel [vx,vy,age,seed], global_rgba [r,g,b,a] and
    //                  writes the new state back (the runtime ping-pongs read/
    //                  write of each global). drawBuffers:3. Fullscreen pass.
    //   passthrough — fullscreen blit of inputTex -> outputTex for 2D-chain
    //                 continuity (does not touch the agent state).
    //
    // The state textures are created upstream by pointsEmit and INHERITED via the
    // particle pipeline (flock's own `textures` is {}); they are rgba32f and
    // persist frame-to-frame (ref 04: isStateSurface matches bare xyz|vel|rgba).
    // NO deposit (drawMode:"points") pass and NO diffuse pass exist in flock — the
    // scatter/render lives in the separate pointsRender effect. Both passes here
    // are fullscreen and use NMVertFullscreen. The runtime rebinds each pass's
    // input/output textures and sets named uniforms via MaterialPropertyBlock by
    // reference names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "agent" (passes[0]) — boids state update, MRT 3 outputs
        Pass
        {
            Name "agent"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_agent
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Flock.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[1]) — inputTex -> outputTex blit
        Pass
        {
            Name "passthrough"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_passthrough
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Flock.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
