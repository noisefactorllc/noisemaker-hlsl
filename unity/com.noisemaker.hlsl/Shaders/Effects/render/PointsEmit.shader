Shader "Noisemaker/render/pointsEmit"
{
    // render/pointsEmit — agent state initializer (3D/RENDER tier middleware).
    // 2 passes per frame in definition order:
    //   init        (program "init", MRT3) — per-agent respawn/persist; writes
    //                                         global_xyz/global_vel/global_rgba.
    //   passthrough (program "passthrough") — copy pipeline input -> outputTex.
    //
    // pointsEmit does NOT draw geometry — both passes are FULLSCREEN over the
    // state textures (NMVertFullscreen). Agent rasterization (points/billboards)
    // is done by the downstream pointsRender / pointsBillboardRender effects.
    //
    // PERSISTENT state textures (runtime persists per ref 04 §10.7, NO swap since
    // they are isStateSurface by suffix '_xyz'/'_vel'/'_rgba'):
    //   global_xyz  (rgba32f) — [x, y, z=0, alive]  positions normalized [0,1]
    //   global_vel  (rgba32f) — [0, 0, rotRand, strideRand]  per-agent randoms
    //   global_rgba (rgba8)   — [r, g, b, a]  agent color sampled from inputTex
    //   Sized stateSize x stateSize; created HERE (outputXyz/Vel/Rgba aliases) and
    //   consumed by downstream agent sims + renderers.
    //
    // The runtime rebinds each pass's input/output textures and sets named
    // uniforms (and samplers) via MaterialPropertyBlock by reference name. The
    // init pass writes all three state textures via MRT (drawBuffers:3).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "init" (passes[0], name "init") — respawn/persist, MRT x3.
        Pass
        {
            Name "init"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_init
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PointsEmit.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[1], name "passthrough") — copy input ->
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
            #include "PointsEmit.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
