Shader "Noisemaker/synth3d/noise3d"
{
    // synth3d/noise3d — 3D gradient/simplex noise VOLUME generator. ONE pass per
    // frame: "precompute" (passes[0]). It is a VOLUME-WRITE pass — the render
    // target is a 2D ATLAS RenderTexture sized volumeSize x volumeSize^2 (default
    // 64 x 4096 == 64 slices of 64x64, rgba16f). The fragment maps atlas pixel
    // (x,y) -> voxel (x, y%volSize, y/volSize) and writes noise density. MRT
    // (drawBuffers:2): SV_Target0 -> volumeCache (color), SV_Target1 -> geoBuffer
    // (geoOut: xyz=normal*0.5+0.5, w=density). The runtime binds both MRT targets
    // (definition.js outputs color/geoOut), sets the viewport to the atlas
    // dimensions, and sets named uniforms via MaterialPropertyBlock by reference
    // name. NO geometry/raymarch here — downstream render3d/renderLit3d raymarchs
    // this atlas into a 2D image (separate effect/shader).
    //
    // NOTE: 3D / multi-output volume-write effect → ships as a runtime-rendered
    // atlas RenderTexture. No Shader Graph Custom Function wrapper is provided.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        // Volume-write fullscreen pass over the atlas. The fragment fully
        // overwrites every voxel each frame (no feedback, no depth) → no depth
        // test/write, no blend. Cull Off (fullscreen triangle).
        ZWrite Off ZTest Always Cull Off

        // progName "precompute" (passes[0]) — volume-write, MRT (drawBuffers:2)
        Pass
        {
            Name "precompute"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_precompute
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Noise3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
