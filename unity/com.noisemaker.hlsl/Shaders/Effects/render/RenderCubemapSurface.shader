Shader "Noisemaker/render/renderCubemapSurface"
{
    // render/renderCubemapSurface — raw true-color cubemap sampler. ONE pass per
    // frame: "render" (passes[0]). It samples a vol-tier volume atlas (volumeCache, a
    // 2D RenderTexture sized volumeSize x volumeSize^2, default 64 x 4096, rgba16f)
    // along the per-face cube camera rays with front-to-back emission/absorption — NO
    // lighting, NO gamma. The pass runs at SCREEN resolution (viewport NOT overridden);
    // the atlas is addressed by INTEGER texel fetch (Texture2D.Load) via volumeToAtlas.
    // The camera sits at the volume center looking out along the per-face basis
    // (cubeBasis); the engine's RenderCubemap loop drives all 6 faces.
    //
    // MRT (drawBuffers:2): SV_Target0 -> color (outputTex), SV_Target1 -> geoOut
    // (screenGeoBuffer). The Surface renderer has no surface, so geoOut is the constant
    // (0.5,0.5,0.5,1.0). The runtime binds both MRT targets and the volumeCache/
    // analyticalGeo inputs, and sets named uniforms via MaterialPropertyBlock by
    // reference name (cubeBasis is a mat3 bound as float4x4; see UniformBinder.
    // BindMatrix3). volumeSize is INHERITED from the upstream volume effect.
    //
    // NOTE: 3D / multi-output / raymarch effect → ships as a runtime-rendered
    // Texture2D. No Shader Graph Custom Function wrapper is provided (3D /
    // multi-pass / MRT).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        // Fullscreen integration over the SCREEN target. The volume is read by texel
        // fetch — no hardware depth test/write needed. The fragment fully writes every
        // screen pixel each frame → Cull Off (fullscreen triangle), no blend.
        ZWrite Off ZTest Always Cull Off

        // progName "renderCubemapSurface" (passes[0]) — volumetric integral, MRT
        Pass
        {
            Name "renderCubemapSurface"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_renderCubemapSurface
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "RenderCubemapSurface.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
