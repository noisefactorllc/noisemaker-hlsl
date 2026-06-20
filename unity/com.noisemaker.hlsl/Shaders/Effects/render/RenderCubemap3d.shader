Shader "Noisemaker/render/renderCubemap3d"
{
    // render/renderCubemap3d — multi-face clone of render3d. ONE pass per frame:
    // "render" (passes[0]). It RAYMARCHES a vol-tier volume atlas (volumeCache, a 2D
    // RenderTexture sized volumeSize x volumeSize^2, default 64 x 4096, rgba16f) into
    // ONE seamless cube face. The pass runs at SCREEN resolution (viewport NOT
    // overridden); the atlas is addressed by INTEGER texel fetch (Texture2D.Load) via
    // volumeToAtlas, not uv sampling. The camera sits at the volume center looking out
    // along the per-face basis (cubeBasis); the engine's RenderCubemap loop drives all
    // 6 faces by re-rendering with cubeBasis set per face.
    //
    // MRT (drawBuffers:2): SV_Target0 -> color (outputTex), SV_Target1 -> geoOut
    // (screenGeoBuffer): xyz = normal*0.5+0.5, w = depth. The runtime binds both MRT
    // targets and the volumeCache/analyticalGeo inputs, and sets named uniforms via
    // MaterialPropertyBlock by reference name (cubeBasis is a mat3 bound as float4x4;
    // see UniformBinder.BindMatrix3). volumeSize is INHERITED from the upstream volume
    // effect (definition.js control=false).
    //
    // FILTERING (isosurface vs voxel) and INVERT were compile-time defines / WGSL
    // consts in the reference (perf-only DCE); here they are runtime int uniforms
    // branched with [branch]. Defaults FILTERING=0, INVERT=0.
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

        // progName "renderCubemap3d" (passes[0]) — raymarch, MRT (drawBuffers:2)
        Pass
        {
            Name "renderCubemap3d"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_renderCubemap3d
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "RenderCubemap3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
