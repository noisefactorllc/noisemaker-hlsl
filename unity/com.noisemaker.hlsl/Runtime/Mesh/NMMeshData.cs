// NMMeshData.cs — the uploadMeshData path (reference backends/webgl2.js
// uploadMeshData + _uploadMeshTexture). Writes parsed OBJ vertex attributes into the
// 256x256 mesh-surface triplet (mesh0.._positions/_normals/_uvs), reference/04 §8.
//
// The mesh triplet RTs are allocated by SurfaceManager (NOT ping-ponged, never
// recreated on resize). This class fills them with CPU vertex data. On the reference
// WebGL2 path the data goes straight into the texture via texImage2D(RGBA, FLOAT);
// in Unity we copy a float[] into a Texture2D (RGBAFloat / RGBAHalf) and Graphics.Blit
// it into the RenderTexture (RTs cannot be SetPixel'd directly).
//
// Vertex layout (one texel per vertex, x = id % 256, y = id / 256): the render VS
// reads texel (vertexID%width, vertexID/width) via Texture2D.Load(int3(x,y,0)), so the
// staging Texture2D MUST be written row-major with NO Y-flip — texel (x,y) here maps to
// Load coords (x,y) in the shader. The vertexCount returned is used to set the draw
// count (count:"input" resolves to width*height; the unused texels carry w=0 so the VS
// can early-out / degenerate them — see ResolveDraw triangles below).
//
// TODO(verify): no Unity in this session. Confirm at runtime that:
//   1. Texture2D(RGBAFloat) -> Blit -> RenderTexture(ARGBFloat) preserves full f32
//      precision for positions (no half-float clamp). normals/uvs tolerate ARGBHalf.
//   2. The 256x256 staging upload orientation matches the VS Load() texel mapping.

using UnityEngine;

namespace Noisemaker.Hlsl
{
    public sealed class NMMeshData
    {
        private readonly TextureStore _store;
        private readonly SurfaceManager _surfaces;

        // Reused staging Texture2Ds per attribute (avoid realloc on re-upload).
        private Texture2D _posStaging, _normStaging, _uvStaging;

        // Last uploaded vertex count per mesh surface (for count:"input"/draw count).
        private readonly System.Collections.Generic.Dictionary<string, int> _vertexCounts =
            new System.Collections.Generic.Dictionary<string, int>();

        public NMMeshData(TextureStore store, SurfaceManager surfaces)
        {
            _store = store;
            _surfaces = surfaces;
        }

        // Vertices actually written for a mesh surface ("mesh0".."mesh7"); 0 if none.
        public int GetVertexCount(string meshName)
        {
            int c;
            return _vertexCounts.TryGetValue(meshName, out c) ? c : 0;
        }

        // Parse an OBJ string and upload it into the named mesh surface (loadOBJ +
        // uploadMeshData fused; the reference loadOBJ just fetches text then parseOBJ).
        public int UploadObj(string meshName, string objText)
        {
            NMMeshArrays mesh = NMObjLoader.ParseObj(objText);
            return UploadParsed(meshName, mesh);
        }

        // uploadMeshData(meshId, positionData, normalData, uvData, w, h, vertexCount).
        public int UploadParsed(string meshName, NMMeshArrays mesh)
        {
            SurfaceRecord rec = _surfaces.GetSurface(meshName);
            if (rec == null || !rec.IsMesh)
            {
                Debug.LogError("[Noisemaker] uploadMeshData: no mesh surface '" +
                    meshName + "'. Ensure a pass references global_" + meshName +
                    "_positions so SurfaceManager allocates the triplet.");
                return 0;
            }

            int w = SurfaceManager.MeshTexSize; // 256
            int h = SurfaceManager.MeshTexSize; // 256

            float[] posData, normData, uvData;
            int used;
            NMObjLoader.PackForTextures(mesh, w, h, out posData, out normData, out uvData, out used);

            // positions: full-precision RGBAFloat (matches rgba32f surface).
            UploadAttr(ref _posStaging, rec.Positions, posData, w, h, TextureFormat.RGBAFloat);
            // reference uploads normals as rgba32f and uvs as rgba16f; the SurfaceManager
            // allocates all three as ARGBFloat, so stage both as RGBAFloat for parity of
            // the surface contents (the VS only needs ~half precision for normals/uvs).
            UploadAttr(ref _normStaging, rec.Normals, normData, w, h, TextureFormat.RGBAFloat);
            UploadAttr(ref _uvStaging, rec.Uvs, uvData, w, h, TextureFormat.RGBAFloat);

            _vertexCounts[meshName] = used;
            return used;
        }

        // Copy a packed float[] (rgba per texel) into a staging Texture2D, then Blit it
        // into the destination RenderTexture. RTs cannot be SetPixel'd, so a staging
        // CPU texture is required (reference texImage2D path is implicit in WebGL).
        private void UploadAttr(ref Texture2D staging, string rtId, float[] rgba,
            int w, int h, TextureFormat fmt)
        {
            RenderTexture rt = _store.Get(rtId);
            if (rt == null)
            {
                Debug.LogError("[Noisemaker] uploadMeshData: missing RT '" + rtId + "'.");
                return;
            }

            if (staging == null || staging.width != w || staging.height != h ||
                staging.format != fmt)
            {
                if (staging != null)
                {
#if UNITY_EDITOR
                    Object.DestroyImmediate(staging);
#else
                    Object.Destroy(staging);
#endif
                }
                // linear color space (no sRGB) to match the LINEAR rgba32f surface.
                staging = new Texture2D(w, h, fmt, false, true);
                staging.filterMode = FilterMode.Point; // exact texel Load, no filtering
                staging.wrapMode = TextureWrapMode.Clamp;
            }

            // SetPixelData writes the raw float buffer row-major (no Y-flip), matching
            // the VS texel mapping (x = id%w, y = id/w). One Color (RGBA) == 4 floats.
            staging.SetPixelData(rgba, 0);
            staging.Apply(false, false);

            // Blit copies the staging texture verbatim into the RT (no scaling: same
            // dims). Graphics.Blit uses a fullscreen copy; with matching 256x256 dims and
            // Point filtering, texel (x,y) -> RT texel (x,y).
            // TODO(verify): Graphics.Blit applies the source as a fullscreen quad with
            // the default blit material, which can Y-flip depending on the active RP.
            // If a flip is observed, use Graphics.CopyTexture(staging,0,0, rt,0,0) instead
            // (exact texel copy, no shader) — guarded by CopyTexture support flags.
            if (SystemInfo.copyTextureSupport != UnityEngine.Rendering.CopyTextureSupport.None)
                Graphics.CopyTexture(staging, 0, 0, rt, 0, 0); // exact texel copy
            else
                Graphics.Blit(staging, rt);
        }

        public void Dispose()
        {
            DestroyStaging(ref _posStaging);
            DestroyStaging(ref _normStaging);
            DestroyStaging(ref _uvStaging);
            _vertexCounts.Clear();
        }

        private static void DestroyStaging(ref Texture2D t)
        {
            if (t == null) return;
#if UNITY_EDITOR
            Object.DestroyImmediate(t);
#else
            Object.Destroy(t);
#endif
            t = null;
        }
    }
}
