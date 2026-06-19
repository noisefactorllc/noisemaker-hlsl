Shader "Noisemaker/points/dla"
{
    // points/dla — Diffusion-Limited Aggregation (agent sim). 5 passes per
    // frame in definition order: initGrid, copyGrid, agent (MRT x3),
    // depositGrid (POINTS scatter, Blend One One), passthrough.
    //
    // PERSISTENT state textures (runtime ping-pongs / persists per ref 04 §10.7):
    //   global_xyz / global_vel / global_rgba (rgba32f) — agent state-surfaces,
    //   produced by pointsEmit, updated in place; consumed by pointsRender.
    //   global_dla_grid (rgba16f) — anchor grid feedback surface.
    //
    // The runtime rebinds each pass's input/output textures and sets named
    // uniforms via MaterialPropertyBlock by reference name. The depositGrid pass
    // is drawn with DrawProcedural(Points, stateSize*stateSize); its vertex stage
    // reads agent state via Texture2D.Load (SM4.5).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "initGrid" (passes[0]) — decay + reseed anchor grid
        Pass
        {
            Name "initGrid"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_initGrid
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Dla.hlsl"
            ENDHLSL
        }

        // progName "copyGrid" (passes[1]) — blit grid to write buffer
        Pass
        {
            Name "copyGrid"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_copyGrid
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Dla.hlsl"
            ENDHLSL
        }

        // progName "agent" (passes[2]) — random walk + stick detection (MRT x3)
        Pass
        {
            Name "agent"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_agent
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Dla.hlsl"
            ENDHLSL
        }

        // progName "depositGrid" (passes[3]) — POINTS scatter, additive deposit.
        // Custom vertex stage (one point per agent); D3D points are 1px.
        Pass
        {
            Name "depositGrid"
            Blend One One
            HLSLPROGRAM
            #pragma vertex vert_deposit
            #pragma fragment frag_deposit
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Dla.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[4]) — composite grid over input
        Pass
        {
            Name "passthrough"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_passthrough
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Dla.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
