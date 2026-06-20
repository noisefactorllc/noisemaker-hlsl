Shader "Noisemaker/filter3d/palette3d"
{
    // filter3d/palette3d — 3D port of filter/palette. ONE render pass over the volume
    // atlas (volumeCache, volumeSize x volumeSize^2, rgba16f): recolor each voxel by
    // luminance -> one of 55 cosine palettes (RGB/HSV/OkLab), reusing the 2D palette's
    // nm_palette() verbatim. Geometry (normals + density) passes through unchanged via
    // outputGeo:"inputGeo" (runtime-level; nothing geometric in the shader).
    //
    // The runtime binds inputTex3d and the volumeCache output; the viewport and
    // _NM_Resolution come from the volumeCache RT size (the atlas), so the whole atlas
    // is recolored. volumeSize is INHERITED from the upstream 3D generator.
    //
    // NOTE: 3D / volume effect → runtime-rendered Texture2D atlas. No Shader Graph
    // Custom Function wrapper (3D volume I/O).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "palette3d" (definition.js passes[0].program)
        Pass
        {
            Name "palette3d"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_palette3d
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Palette3d.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
