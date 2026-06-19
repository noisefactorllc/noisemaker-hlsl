Shader "Noisemaker/filter/wormhole"
{
    // filter/wormhole — Luminance-driven scatter displacement. MULTI-PASS /
    // POINTS-SCATTER (no persistent agent state, no feedback). 3 passes per frame
    // in definition order:
    //   clear   (fullscreen)        — zero wormhole_accum
    //   deposit (drawMode:points)   — scatter each INPUT pixel into wormhole_accum,
    //                                 additive Blend One One; count = inputTex.w *
    //                                 inputTex.h (one DrawProcedural Points vertex
    //                                 per input pixel); vertex reads inputTex per
    //                                 SV_VertexID and emits a 1px point.
    //   blend   (fullscreen)        — mean-normalize + sqrt accum, lerp with input.
    // wormhole_accum is a TRANSIENT POOLED graph texture (rgba16f, full-res),
    // recomputed each frame; it is NOT 'global_'-prefixed and NOT persisted. The
    // runtime rebinds each pass's input/output textures and sets named uniforms
    // (kink/stride/rotation/wrap/alpha) and the inputTex/accumTex samplers via
    // MaterialPropertyBlock by reference names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "clear" (passes[0]) — zero the accumulation texture
        Pass
        {
            Name "clear"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_clear
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Wormhole.hlsl"
            ENDHLSL
        }

        // progName "deposit" (passes[1]) — points-scatter input pixels into accum
        // drawMode:"points", count:"input" (N = inputTex.w*inputTex.h); custom
        // SV_VertexID vertex; additive accumulation into the float accum texture.
        Pass
        {
            Name "deposit"
            Blend One One
            HLSLPROGRAM
            #pragma vertex vert_deposit
            #pragma fragment frag_deposit
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Wormhole.hlsl"
            ENDHLSL
        }

        // progName "blend" (passes[2]) — normalize/sqrt accum, blend with original
        Pass
        {
            Name "blend"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_blend
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Wormhole.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
