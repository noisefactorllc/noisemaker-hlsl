Shader "Noisemaker/filter3d/flow3d"
{
    // filter3d/flow3d — 3D agent-based flow field (3D / RENDER tier). 5 passes
    // per frame in definition order:
    //   agent    (program "agent",   MRT3)        — 3D GPGPU agent sim; writes
    //                                                outState1/2/3 over the 512x512
    //                                                state grid.
    //   diffuse  (program "diffuse")              — decay the trail volume atlas
    //                                                by persistence (intensity/100).
    //   copy     (program "copy")                 — blit decayed trail to write
    //                                                buffer before deposit.
    //   deposit  (program "deposit", POINTS scatter, Blend One One) — one 1px point
    //                                                per agent (count=262144); vertex
    //                                                stage Loads agent 3D pos, maps
    //                                                to volume-atlas NDC, scatters
    //                                                color additively.
    //   blend    (program "blend")                — combine input volume (inputTex3d)
    //                                                with trail volume → blended
    //                                                output volume (outputTex3d).
    //
    // VOLUME ATLAS: PRIVATE 'global_' atlas surfaces sized (volumeSize) x
    // (volumeSize^2), rgba16f (NOT the shared 64x4096 vol0..7). Atlas (u,v)->(x,y,z):
    //   x=u, y=v%volSize, z=v/volSize  → atlasY = y_voxel + z_voxel*volSize.
    //
    // PERSISTENT state textures (runtime ping-pongs / persists per ref 04 §10.7):
    //   global_flow3d_state1/2/3 (rgba16f, 512x512) — agent state-surfaces (name
    //     contains 'state' → isStateSurface=true; end-of-frame bindings persist,
    //     no swap). agent updates all three via MRT (drawBuffers:3).
    //   global_flow3d_trail (rgba16f, atlas) — private trail feedback surface:
    //     decayed by diffuse, copied by copy, additively deposited into by deposit
    //     (Blend One One), read by blend. Reads its own prior 'global_' output so
    //     it persists (runtime double-buffers; §10.2/§10.7). NOT isStateSurface.
    //   global_flow3d_blended (rgba16f, atlas) — output volume (outputTex3d).
    //   geoBuffer (rgba16f, atlas) — declared outputGeo; xyz=normal,w=depth, written
    //     by a DOWNSTREAM render3d/renderLit3d raymarch (NOT by flow3d).
    //
    // The runtime rebinds each pass's input/output textures and sets named
    // uniforms (and samplers) via MaterialPropertyBlock by reference name. The
    // deposit pass is drawn with DrawProcedural(Points, 262144); its vertex stage
    // reads agent state via Texture2D.Load (SM4.5). D3D points are 1px.
    //
    // All passes are GPGPU writes to 2D atlas render targets (no real depth):
    // ZWrite Off, ZTest Always, Cull Off. deposit adds Blend One One.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "agent" (passes[0]) — 3D GPGPU agent sim, MRT x3.
        Pass
        {
            Name "agent"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_agent
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Flow3d.hlsl"
            ENDHLSL
        }

        // progName "diffuse" (passes[1]) — decay trail volume by persistence.
        Pass
        {
            Name "diffuse"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_diffuse
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Flow3d.hlsl"
            ENDHLSL
        }

        // progName "copy" (passes[2]) — blit decayed trail to write buffer.
        Pass
        {
            Name "copy"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_copy
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Flow3d.hlsl"
            ENDHLSL
        }

        // progName "deposit" (passes[3]) — POINTS scatter into trail atlas,
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
            #include "Flow3d.hlsl"
            ENDHLSL
        }

        // progName "blend" (passes[4]) — combine input volume + trail → blended.
        Pass
        {
            Name "blend"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_blend
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Flow3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
