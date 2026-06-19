Shader "Noisemaker/points/physarum"
{
    // points/physarum — Physarum slime-mold agent sim (Common Agent
    // Architecture middleware). 5 passes per frame in definition order:
    //   decayTrail   (program "diffuse")     — apply persistence to the pheromone
    //   agent        (program "agent", MRT3) — sensor-based steering, writes state
    //   copy         (program "passthrough") — blit decayed pheromone to write buf
    //   deposit      (program "deposit", POINTS scatter, Blend One One) — additive
    //                                          scatter of agent pheromones
    //   passthrough  (program "passthrough") — copy input -> output (2D continuity)
    //
    // PERSISTENT state textures (runtime ping-pongs / persists per ref 04 §10.7):
    //   global_xyz / global_vel / global_rgba (rgba32f) — agent state-surfaces,
    //     produced by pointsEmit, updated in place by the agent pass; consumed by
    //     pointsRender. isStateSurface=true (suffix '_xyz'/'_vel'/'_rgba').
    //   global_physarum_pheromone (rgba16f, 100%) — private pheromone/chemistry
    //     feedback surface: decayed by decayTrail, copied by copy, additively
    //     deposited into by deposit (Blend One One), sensed by agent. Reads its own
    //     prior 'global_' output so it persists (runtime double-buffers; §10.2/§10.7).
    //
    // The runtime rebinds each pass's input/output textures and sets named uniforms
    // (and samplers) via MaterialPropertyBlock by reference name. The deposit pass
    // is drawn with DrawProcedural(Points, stateSize*stateSize); its vertex stage
    // reads agent state via Texture2D.Load (SM4.5). D3D points are 1px.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "diffuse" (passes[0], name "decayTrail") — decay pheromone.
        Pass
        {
            Name "decayTrail"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_diffuse
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Physarum.hlsl"
            ENDHLSL
        }

        // progName "agent" (passes[1], name "agent") — sensor steering, MRT x3.
        Pass
        {
            Name "agent"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_agent
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Physarum.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[2], name "copy") — blit pheromone to
        // write buffer before deposit (inputTex == global_physarum_pheromone).
        Pass
        {
            Name "copy"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_passthrough
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Physarum.hlsl"
            ENDHLSL
        }

        // progName "deposit" (passes[3], name "deposit") — POINTS scatter,
        // additive (Blend One One). Custom vertex stage (one 1px point per agent).
        Pass
        {
            Name "deposit"
            Blend One One
            HLSLPROGRAM
            #pragma vertex vert_deposit
            #pragma fragment frag_deposit
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Physarum.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[4], name "passthrough") — copy input ->
        // output for 2D-chain continuity (inputTex == pipeline input).
        Pass
        {
            Name "passthrough"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_passthrough
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Physarum.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
