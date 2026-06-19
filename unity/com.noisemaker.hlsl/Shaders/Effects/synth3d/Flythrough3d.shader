Shader "Noisemaker/synth3d/flythrough3d"
{
    // synth3d/flythrough3d — 3D fractal flythrough VOLUME GENERATOR. ONE pass
    // ("precompute") per frame: a fullscreen draw over the 64x4096 atlas
    // RenderTexture that fills a camera-relative fractal volume. The pass is
    // MRT (drawBuffers:2): SV_Target0 -> volumeCache (rgba16f density field),
    // SV_Target1 -> geoBuffer (rgba16f, xyz=normal*0.5+0.5, w=depth). The atlas
    // packs 64 slices of 64x64; each texel maps to a (vx,vy,vz) voxel. A
    // downstream render3d/renderLit3d effect raymarches the atlas to a 2D image.
    //
    // The runtime binds the two MRT color attachments (volumeCache, geoBuffer)
    // and the custom viewport (atlas dims) and sets named uniforms via
    // MaterialPropertyBlock. NO geometry rasterization here — this is a
    // fullscreen volume fill, so standard fullscreen render state applies
    // (ZWrite Off / ZTest Always / Cull Off). Half-float linear RTs (ARGBHalf).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "precompute" (passes[0]) — volume-write + geo MRT
        Pass
        {
            Name "precompute"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_precompute
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Flythrough3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
