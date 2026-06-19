Shader "Noisemaker/render/renderLit3d"
{
    // render/renderLit3d — Universal 3D VOLUME RAYMARCHER with advanced
    // (Blinn-Phong + rim) lighting. ONE pass per frame ("render"): a fullscreen
    // draw at SCREEN resolution that raymarches an input vol-tier atlas into a
    // lit 2D image. MRT (drawBuffers:2):
    //   SV_Target0 (color)  -> outputTex        (lit RGB + alpha, gamma 1/2.2)
    //   SV_Target1 (geoOut) -> screenGeoBuffer  (xyz=normal*0.5+0.5, w=depth)
    //
    // INPUTS (runtime binds per definition.js inputs{}):
    //   volumeCache   <- inputTex3d  : vol-tier 2D atlas (volumeSize x
    //                                  volumeSize^2, default 64x4096, rgba16f
    //                                  LINEAR). Read via Load (point fetch);
    //                                  trilinear filtering done MANUALLY.
    //   analyticalGeo <- inputGeo    : geo-tier atlas, BOUND but never sampled
    //                                  by the body (declared for parity only).
    //
    // This is a fullscreen volume CONSUMER (no geometry rasterization, no
    // feedback). Depth is written into the geo buffer's w channel, NOT the GPU
    // depth buffer — so standard fullscreen render state applies (ZWrite Off /
    // ZTest Always / Cull Off). Half-float linear RTs (ARGBHalf). The runtime
    // binds the two MRT color attachments and sets named uniforms (and the
    // volumeCache/analyticalGeo samplers) via MaterialPropertyBlock.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "render" (passes[0]) — raymarch + lighting, MRT drawBuffers:2
        Pass
        {
            Name "render"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_render
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "RenderLit3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
