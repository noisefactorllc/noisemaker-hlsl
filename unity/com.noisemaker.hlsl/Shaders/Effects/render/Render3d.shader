Shader "Noisemaker/render/render3d"
{
    // render/render3d — Universal 3D volume RAYMARCHER. ONE pass per frame:
    // "render" (passes[0]). It RAYMARCHES a vol-tier volume atlas (volumeCache,
    // a 2D RenderTexture sized volumeSize x volumeSize^2, default 64 x 4096 =
    // 64 slices of 64x64, rgba16f) into a 2D SCREEN image. The pass runs at
    // SCREEN resolution (viewport NOT overridden); the atlas is addressed by
    // INTEGER texel fetch (Texture2D.Load) via volumeToAtlas, not uv sampling.
    //
    // MRT (drawBuffers:2): SV_Target0 -> color (outputTex), SV_Target1 ->
    // geoOut (screenGeoBuffer): xyz = normal*0.5+0.5, w = depth. The runtime
    // binds both MRT targets and the volumeCache/analyticalGeo inputs, and sets
    // named uniforms via MaterialPropertyBlock by reference name. volumeSize is
    // INHERITED from the upstream volume effect (definition.js control=false).
    //
    // FILTERING (isosurface vs voxel) and INVERT were compile-time defines /
    // WGSL consts in the reference (perf-only DCE); here they are runtime int
    // uniforms branched with [branch]. Defaults FILTERING=0, INVERT=0.
    //
    // NOTE: 3D / multi-output / raymarch effect → ships as a runtime-rendered
    // Texture2D. No Shader Graph Custom Function wrapper is provided (3D /
    // multi-pass / MRT).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        // Fullscreen raymarch over the SCREEN target. Depth is written into the
        // geo buffer's alpha channel (NOT hardware Z), and the volume is read
        // by texel fetch — no hardware depth test/write needed. The fragment
        // fully writes every screen pixel each frame → Cull Off (fullscreen
        // triangle), no blend.
        ZWrite Off ZTest Always Cull Off

        // progName "render3d" (passes[0]) — raymarch, MRT (drawBuffers:2)
        Pass
        {
            Name "render3d"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_render3d
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Render3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
