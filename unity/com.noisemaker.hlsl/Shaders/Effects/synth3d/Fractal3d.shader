Shader "Noisemaker/synth3d/fractal3d"
{
    // synth3d/fractal3d — 3D Mandelbulb/Mandelcube fractal VOLUME GENERATOR.
    // Single pass "precompute" (passes[0]), MRT drawBuffers:2. Renders a
    // volumeSize x volumeSize^2 (default 64 x 4096, rgba16f) 2D ATLAS that
    // encodes a volumeSize^3 voxel volume as stacked Z-slices (reference 04 §8,
    // reference 10 §3.7/§4.2). Atlas pixel (x,y) -> voxel (x, y%volSize,
    // y/volSize). MRT attachment order matches the WGSL FragOutput:
    //   color  = SV_Target0 -> volumeCache (vol: r=dist g=trap b=iter a=1)
    //   geoOut = SV_Target1 -> geoBuffer   (geo: xyz=normal*0.5+0.5, w=dist)
    // The viewport is the ATLAS, not the screen (definition viewport =
    // volumeSize x volumeSize^2). The runtime sets the named uniforms via
    // MaterialPropertyBlock and binds the two MRT render targets per the
    // definition outputs{}. Pure generator: no input textures, no feedback,
    // no repeat. Consumed downstream by render/render3d or render/renderLit3d
    // (which raymarch the atlas). No Shader Graph wrapper (3D / MRT).


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        // Volume-write atlas pass: no depth, no culling, no blend (overwrite).
        ZWrite Off ZTest Always Cull Off

        // progName "precompute" (passes[0]) — fractal volume atlas, MRT 2 outputs
        Pass
        {
            Name "precompute"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_precompute
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Fractal3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
