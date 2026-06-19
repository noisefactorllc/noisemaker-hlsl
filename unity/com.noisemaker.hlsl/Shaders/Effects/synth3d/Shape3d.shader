Shader "Noisemaker/synth3d/shape3d"
{
    // synth3d/shape3d — 3D polyhedral / primitive shape-volume generator.
    // 1 pass per frame (definition order): precompute.
    //
    // VOLUME-WRITE: the single "precompute" pass renders a fullscreen triangle
    // over an ATLAS-sized target (volumeSize x volumeSize^2, default 64x4096,
    // rgba16f). It is MRT (drawBuffers:2): SV_Target0 -> volumeCache (scalar
    // field), SV_Target1 -> geoBuffer (xyz=normal, w=field). No input texture.
    // The runtime binds the atlas viewport + the two MRT targets and sets the
    // named uniforms (loopAOffset/loopBOffset/loopAScale/loopBScale/speedA/
    // speedB/volumeSize/colorMode) via MaterialPropertyBlock by reference name.
    // The volume atlas is consumed downstream by render/render3d (raymarch).
    //
    // No display surface is produced here (outputTex3d=volumeCache,
    // outputGeo=geoBuffer). ZWrite Off / ZTest Always / Cull Off / Blend Off:
    // this is an off-screen GPGPU-style atlas fill, NOT depth-tested geometry.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "precompute" (passes[0]) — atlas volume-write, MRT x2
        Pass
        {
            Name "precompute"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_precompute
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Shape3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
