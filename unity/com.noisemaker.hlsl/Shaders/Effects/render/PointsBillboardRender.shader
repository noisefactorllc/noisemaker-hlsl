Shader "Noisemaker/render/pointsBillboardRender"
{
    // render/pointsBillboardRender — render particle agents as camera-facing
    // billboard sprite quads (SDF shapes or a sprite texture). 4 passes per
    // frame in definition order:
    //   diffuse (program "diffuse", fullscreen)            — decay the trail
    //                                                        (persistence = intensity)
    //   copy    (program "copy",    fullscreen)            — blit decayed trail to the
    //                                                        write buffer before deposit
    //   deposit (program "deposit", BILLBOARDS scatter,    — additive scatter of agent
    //            Blend One One)                              billboard quads into trail
    //   blend   (program "blend",   fullscreen)            — alpha-composite trail over
    //                                                        the scaled pipeline input
    //
    // SURFACES (runtime ping-pongs / persists per ref 04 §10.2/§10.7):
    //   global_xyz  (rgba32f) — agent positions [x,y,z,alive] from pointsEmit;
    //     read (Load) by the deposit VERTEX stage. isStateSurface (suffix '_xyz').
    //   global_rgba (rgba32f) — agent color [r,g,b,a] from pointsEmit; read (Load)
    //     by the deposit VERTEX stage. isStateSurface (suffix '_rgba').
    //   global_billboard_trail (rgba16f, 100%) — PERSISTENT private accumulation
    //     trail: decayed by diffuse, copied by copy, additively deposited into by
    //     deposit (Blend One One), composited with input by blend. Reads its own
    //     prior 'global_' output so it persists (runtime double-buffers; §10.2/§10.7).
    //
    // The runtime rebinds each pass's input/output textures and sets named uniforms
    // (and samplers) via MaterialPropertyBlock by reference name. The deposit pass
    // is drawn with DrawProcedural(Triangles, stateSize*stateSize*6); its vertex
    // stage reads agent state via Texture2D.Load (SM4.5) and emits 6 verts (two
    // triangles) per agent as a rotated, size-varied billboard quad.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "diffuse" (passes[0]) — decay the trail.
        Pass
        {
            Name "diffuse"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_diffuse
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PointsBillboardRender.hlsl"
            ENDHLSL
        }

        // progName "copy" (passes[1]) — blit decayed trail to the write buffer.
        Pass
        {
            Name "copy"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_copy
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PointsBillboardRender.hlsl"
            ENDHLSL
        }

        // progName "deposit" (passes[2]) — BILLBOARD scatter, additive (Blend One
        // One). Custom vertex stage: 6 verts (two triangles) per agent quad.
        // DrawProcedural(Triangles, stateSize*stateSize*6). Cull Off (quad winding
        // varies with per-particle rotation; off-screen cull handled in VS).
        Pass
        {
            Name "deposit"
            Blend One One
            Cull Off
            HLSLPROGRAM
            #pragma vertex vert_deposit
            #pragma fragment frag_deposit
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PointsBillboardRender.hlsl"
            ENDHLSL
        }

        // progName "blend" (passes[3]) — composite trail over scaled input.
        Pass
        {
            Name "blend"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_blend
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PointsBillboardRender.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
