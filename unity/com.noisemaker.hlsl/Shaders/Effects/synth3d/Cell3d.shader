Shader "Noisemaker/synth3d/cell3d"
{
    // synth3d/cell3d — 3D cellular/Voronoi noise VOLUME generator. ONE pass:
    // "precompute" (volume-write, MRT drawBuffers:2). The render target is the
    // canonical vol surface — a volumeSize x volumeSize^2 rgba16f ATLAS (default
    // 64x4096 = 64 slices of 64x64; reference 04 §8.4). One fullscreen fragment
    // maps atlas pixel (x,y) -> voxel (x, y%volSize, y/volSize), evaluates 3D
    // Worley/cell noise, and writes TWO attachments:
    //   SV_Target0 color  -> volumeCache (vol surface)
    //   SV_Target1 geoOut -> geoBuffer   (geo surface)
    // The runtime binds the two render targets (vol + geo) as MRT and sets the
    // named uniforms via MaterialPropertyBlock. The render viewport is the atlas
    // size (volumeSize x volumeSize^2), NOT the display resolution. Downstream
    // render3d/renderLit3d RAYMARCHES this atlas into a 2D image. ZWrite/ZTest
    // are irrelevant here (no depth buffer for an off-screen atlas write); we use
    // the standard fullscreen state ZWrite Off / ZTest Always / Cull Off / no blend.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "precompute" (passes[0]) — volume-write, MRT (color, geoOut)
        Pass
        {
            Name "precompute"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_precompute
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Cell3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
