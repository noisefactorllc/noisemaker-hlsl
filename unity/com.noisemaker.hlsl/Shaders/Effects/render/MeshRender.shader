Shader "Noisemaker/render/meshRender"
{
    // render/meshRender — rasterize an OBJ mesh with Blinn-Phong lighting.
    // 3D / RENDER tier (geometry rasterization). 2 passes per frame in
    // definition order:
    //   clear  (program "clear",  fullscreen)            fill output with the bg
    //                                                    color (premultiplied alpha)
    //   render (program "render", drawMode "triangles")  rasterize mesh triangles;
    //                                                    the VS reads vertex
    //                                                    attributes from the mesh
    //                                                    data textures by SV_VertexID
    //
    // MESH SURFACES (reference 04 §8 / §10.3): the global mesh0 surface is a
    // TRIPLET of 256x256 rgba32f textures uploaded CPU-side by render/meshLoader
    // (uploadMeshData / loadOBJ), NOT ping-ponged (static):
    //   global_mesh0_positions (xyz=world pos, w=valid)  bound to meshPositions
    //   global_mesh0_normals   (xyz=normal,   w unused)  bound to meshNormals
    // The render pass is issued as DrawProcedural(Triangles, count) where
    // count = meshPositions.width*height = 256*256 = 65536 (definition count:
    // 'input'); the vertex stage Loads attributes (SM4.5) and projects to clip.
    //
    // DEPTH / CULL (reference webgl2 backend 'triangles' branch): the render pass
    // runs with DEPTH_TEST gl.LESS, depthMask on, CULL_FACE BACK, frontFace CCW,
    // and CLEARS the depth buffer for the pass. Mirrored below: the render pass is
    // ZWrite On, ZTest LEqual, Cull Back (the runtime clears depth before the
    // pass). The clear pass is a plain fullscreen blit (ZWrite Off / ZTest Always
    // / Cull Off). clipPos.y is flipped in the VS exactly as the WGSL does
    // (D3D/WebGPU top-left clip). The runtime rebinds each pass's input/output
    // textures and sets named uniforms (and the mesh-data textures) via
    // MaterialPropertyBlock by reference name.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        // progName "clear" (passes[0], name "clear") — fullscreen bg fill.
        Pass
        {
            Name "clear"
            ZWrite Off ZTest Always Cull Off
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_clear
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "MeshRender.hlsl"
            ENDHLSL
        }

        // progName "render" (passes[1], name "render") — geometry rasterization.
        // drawMode "triangles", count 'input' (= meshPositions w*h = 65536).
        // Custom vertex stage reads mesh attributes by SV_VertexID (SM4.5).
        // Reference depth intent: DEPTH_TEST LESS + depthMask + Cull Back, depth
        // cleared per-pass by the runtime → ZWrite On, ZTest LEqual, Cull Back.
        Pass
        {
            Name "render"
            ZWrite On ZTest LEqual Cull Back
            Blend Off
            HLSLPROGRAM
            #pragma vertex vert_render
            #pragma fragment frag_render
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "MeshRender.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
