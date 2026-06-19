Shader "Noisemaker/synth3d/cellularAutomata3d"
{
    // synth3d/cellularAutomata3d — 3D cellular-automata volume simulation.
    // ONE pass per frame ("simulate"). The pass is a fullscreen GPGPU draw that
    // WRITES a 2D ATLAS RenderTexture encoding a 3D voxel volume (width
    // volumeSize, height volumeSize^2 — volumeSize Z-slices stacked vertically;
    // see CellularAutomata3d.hlsl for the atlas (u,v)->(x,y,z) mapping). It is
    // NOT geometry — no rasterized depth — so it uses fullscreen-triangle
    // ZWrite Off / ZTest Always / Cull Off, exactly like the GPGPU sim
    // exemplars (NavierStokes / reactionDiffusion).
    //
    // The persistent state atlas global_ca_state (r=alive, g=age, b=alive, a=1)
    // is BOTH the input (stateTex) and the output; the runtime ping-pongs it so
    // each frame reads the previous frame's volume (reference 04 §10.2/§10.7,
    // isStateSurface matches on "state"). seedTex is the upstream 'source'
    // volume (inputTex3d), used for first-frame / reset seeding and optional
    // weight blending. The runtime rebinds stateTex/seedTex and sets the named
    // uniforms via MaterialPropertyBlock by reference name. Downstream
    // render3d/renderLit3d raymarches the resulting atlas to screen.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "simulate" (passes[0]) — step the 3D CA volume atlas
        Pass
        {
            Name "simulate"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_simulate
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "CellularAutomata3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
