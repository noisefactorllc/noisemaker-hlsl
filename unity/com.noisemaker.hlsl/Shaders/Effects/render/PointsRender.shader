Shader "Noisemaker/render/pointsRender"
{
    // render/pointsRender — blend agent trails with input for particle systems.
    // 4 passes per frame in definition order:
    //   diffuse (program "diffuse")  — decay the visual trail (trail *= clamp(intensity/100))
    //   copy    (program "copy")     — blit decayed trail to write buffer (ping-pong fix)
    //   deposit (program "deposit", POINTS scatter, Blend One One) — scatter agent colors
    //                                  to the trail (one 1px point per alive/density-passing agent)
    //   blend   (program "blend")    — composite trail with input -> outputTex
    //
    // PERSISTENT state texture (runtime ping-pongs / persists per ref 04 §10.7):
    //   global_points_trail (rgba16f, 100%) — visual trail accumulation. Reads its own
    //     prior 'global_' output so it persists (runtime double-buffers; §10.2/§10.7).
    //     isStateSurface=true (suffix '_trail') → end-of-frame bindings persist (no swap).
    //   global_xyz / global_rgba (rgba32f) — agent state-surfaces produced upstream by
    //     pointsEmit; READ-ONLY here (consumed by the deposit vertex stage via Load).
    //
    // The runtime rebinds each pass's input/output textures and sets named uniforms
    // (and samplers) via MaterialPropertyBlock by reference name. The deposit pass is
    // drawn with DrawProcedural(Points, stateSize*stateSize) (count='input' = xyzTex
    // dims squared); its vertex stage reads agent state via Texture2D.Load (SM4.5).
    // D3D points are 1px.


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
            #include "PointsRender.hlsl"
            ENDHLSL
        }

        // progName "copy" (passes[1]) — blit decayed trail to write buffer.
        Pass
        {
            Name "copy"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_copy
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PointsRender.hlsl"
            ENDHLSL
        }

        // progName "deposit" (passes[2]) — POINTS scatter, additive (Blend One One).
        // Custom vertex stage (one 1px point per agent; 2D/3D view transform).
        Pass
        {
            Name "deposit"
            Blend One One
            HLSLPROGRAM
            #pragma vertex vert_deposit
            #pragma fragment frag_deposit
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PointsRender.hlsl"
            ENDHLSL
        }

        // progName "blend" (passes[3]) — composite trail with input -> outputTex.
        Pass
        {
            Name "blend"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_blend
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "PointsRender.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
