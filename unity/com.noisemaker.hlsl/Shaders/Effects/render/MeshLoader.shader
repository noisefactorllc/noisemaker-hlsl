Shader "Noisemaker/render/meshLoader"
{
    // render/meshLoader — load OBJ mesh data into GPU textures and preview it.
    // 1 pass per frame in definition order:
    //   preview (program "preview") — fullscreen visualization of the loaded
    //                                 mesh0 surface triplet (left half = positions,
    //                                 right half = normals).
    //
    // MESH TIER surfaces (reference 04 §8): the mesh0 surface triplet
    //   global_mesh0_positions / global_mesh0_normals / global_mesh0_uvs
    //   (each 256x256, rgba32f) holds STATIC vertex data uploaded CPU-side by the
    //   runtime (uploadMeshData) — the effect declares externalMesh="mesh0" and
    //   the demo UI calls loadOBJFromURL to populate it. This effect runs NO
    //   geometry/scatter pass; the preview pass only SAMPLES the uploaded textures.
    //
    // The runtime rebinds positionsTex/normalsTex to the mesh0 surface textures
    // and sets engine globals (resolution/tileOffset/fullResolution) via a
    // MaterialPropertyBlock by reference name. meshLoader has no scalar uniforms.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "preview" (passes[0]) — fullscreen mesh-data visualization.
        Pass
        {
            Name "preview"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_preview
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "MeshLoader.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
