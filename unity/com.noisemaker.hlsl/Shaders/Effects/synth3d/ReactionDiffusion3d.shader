Shader "Noisemaker/synth3d/reactionDiffusion3d"
{
    // synth3d/reactionDiffusion3d — 3D Gray-Scott reaction-diffusion. ONE pass,
    // "simulate" (repeat:iterations), that WRITES a 2D volume atlas
    // (volumeSize x volumeSize^2, e.g. 32x1024). The fragment decodes its atlas
    // texel -> voxel, runs one diffusion step, and writes back to the SAME
    // atlas. NOT a raymarch: downstream render/render3d raymarches the atlas.
    //
    // STATE: persistent 'global_' surface global_rd_state (rgba16f:
    // r=B/density, g/b=viz, a=A). The runtime ping-pongs it on every write
    // (within-frame + across frames) and re-runs the pass repeat:iterations
    // times/frame; no iteration index is injected. seedTex is the upstream 3D
    // input volume atlas (inputTex3d, from the `source` vol surface). The
    // runtime rebinds stateTex/seedTex and sets named uniforms via
    // MaterialPropertyBlock by reference name, and sets the atlas viewport.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "simulate" (passes[0]) — atlas-write Gray-Scott step
        // (repeat:iterations; runtime ping-pongs global_rd_state per iteration)
        Pass
        {
            Name "simulate"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_simulate
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "ReactionDiffusion3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
