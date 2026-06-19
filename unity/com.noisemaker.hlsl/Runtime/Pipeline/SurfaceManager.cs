// SurfaceManager.cs — global double-buffered surfaces and the 3-tier ping-pong.
//
// Mirrors reference/04 §8 (createSurfaces), §10.2 (within-frame), §10.6
// (per-iteration), §10.7 (end-of-frame swap/persist) and the EXACT isStateSurface
// predicate (§10.7 / hazard 5). Surfaces hold a {read,write} pair of RenderTexture
// ids that live in TextureStore as "global_<name>_read" / "global_<name>_write".
//
// Surface groups (reference/04 §8):
//   1. o0..o7  display, W×H, rgba16f (or graph global_ override)
//   2. dynamic globals  (scanned from pass inputs/outputs: global_<name>, except
//      mesh-data names), spec-resolved size/format
//   3. geo0..geo7  W×H rgba16f
//   4. vol0..vol7  64×4096 rgba16f
//   5. mesh0..mesh7  triplet 256×256 rgba32f  (positions/normals/uvs) — NOT ping-pong
//
// frameRead/frameWrite maps hold the CURRENT per-frame binding for each surface
// (cleared and re-seeded each frame from surface.read/write — reference §10 step 4).

using System.Collections.Generic;
using System.Text.RegularExpressions;
using UnityEngine;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl
{
    // 2D double-buffered surface record (reference SurfaceRecord).
    public sealed class SurfaceRecord
    {
        public string Read;          // texId in TextureStore, "global_<name>_read"
        public string Write;         // "global_<name>_write"
        public int CurrentFrame;
        // mesh-only triplet (group 5); null for double-buffered surfaces.
        public bool IsMesh;
        public string Positions, Normals, Uvs;
    }

    public sealed class SurfaceManager
    {
        public const int VolumeSliceSize = 64;
        public const int VolumeAtlasHeight = 64 * 64; // 4096
        public const int MeshTexSize = 256;

        private readonly TextureStore _store;

        // name -> record. Insertion order preserved for deterministic frame seeding.
        private readonly OrderedMap<string, SurfaceRecord> _surfaces =
            new OrderedMap<string, SurfaceRecord>();

        // Per-frame current bindings (reference frameReadTextures / frameWriteTextures).
        private readonly Dictionary<string, string> _frameRead =
            new Dictionary<string, string>();
        private readonly Dictionary<string, string> _frameWrite =
            new Dictionary<string, string>();

        private static readonly Regex MeshDataPattern =
            new Regex(@"^mesh\d+_(positions|normals|uvs)$", RegexOptions.Compiled);
        private static readonly Regex StateNodePattern =
            new Regex(@"^(xyz|vel|rgba|points_trail)_node_\d+$", RegexOptions.Compiled);

        public SurfaceManager(TextureStore store) { _store = store; }

        public bool HasSurface(string name) { return _surfaces.ContainsKey(name); }

        public SurfaceRecord GetSurface(string name)
        {
            SurfaceRecord r;
            return _surfaces.TryGetValue(name, out r) ? r : null;
        }

        public IEnumerable<string> SurfaceNames { get { return _surfaces.Keys; } }

        // Current read RT for a surface (frame-local override else persistent read).
        public RenderTexture GetFrameReadTexture(string name)
        {
            SurfaceRecord rec = GetSurface(name);
            if (rec == null) return null;
            string id;
            if (!_frameRead.TryGetValue(name, out id)) id = rec.Read;
            return _store.Get(id);
        }

        // Current write target id for a surface.
        public string GetFrameWriteId(string name)
        {
            SurfaceRecord rec = GetSurface(name);
            if (rec == null) return null;
            string id;
            if (_frameWrite.TryGetValue(name, out id)) return id;
            return rec.Write;
        }

        public string GetFrameReadId(string name)
        {
            SurfaceRecord rec = GetSurface(name);
            if (rec == null) return null;
            string id;
            if (_frameRead.TryGetValue(name, out id)) return id;
            return rec.Read;
        }

        // parseGlobalName: "global_<name>" -> <name>, else null (reference §8).
        public static string ParseGlobalName(string texId)
        {
            if (texId == null) return null;
            if (texId.StartsWith("global_", System.StringComparison.Ordinal))
                return texId.Substring("global_".Length);
            return null;
        }

        // isStateSurface (reference/04 §10.7, EXACT, case-sensitive):
        //   exact xyz|vel|rgba|trail; OR suffix _xyz|_vel|_rgba|_trail;
        //   OR name.includes('state')||includes('State');
        //   OR /^(xyz|vel|rgba|points_trail)_node_\d+$/.
        public static bool IsStateSurface(string name)
        {
            if (string.IsNullOrEmpty(name)) return false;
            if (name == "xyz" || name == "vel" || name == "rgba" || name == "trail")
                return true;
            if (name.EndsWith("_xyz", System.StringComparison.Ordinal) ||
                name.EndsWith("_vel", System.StringComparison.Ordinal) ||
                name.EndsWith("_rgba", System.StringComparison.Ordinal) ||
                name.EndsWith("_trail", System.StringComparison.Ordinal))
                return true;
            if (name.IndexOf("state", System.StringComparison.Ordinal) >= 0 ||
                name.IndexOf("State", System.StringComparison.Ordinal) >= 0)
                return true;
            if (StateNodePattern.IsMatch(name)) return true;
            return false;
        }

        // ---- createSurfaces (reference/04 §8) -----------------------------
        // Called from resize. Builds the full surface set. uniforms supplies values
        // for dim resolution of global_ overrides / dynamic globals.
        public void CreateSurfaces(RenderGraph graph, int width, int height,
            System.Func<string, double?> uniforms)
        {
            // Collect the ordered set of double-buffered surface names.
            var names = new List<string>();

            // Group 1: display o0..o7 (always).
            for (int i = 0; i < 8; i++) names.Add("o" + i);

            // Group 2: dynamic globals scanned from passes (skip mesh-data names).
            foreach (Pass pass in graph.Passes)
            {
                ScanGlobals(pass.Inputs, names);
                ScanGlobals(pass.Outputs, names);
            }

            // Group 3: geo0..geo7.
            for (int i = 0; i < 8; i++) AddUnique(names, "geo" + i);
            // Group 4: vol0..vol7.
            for (int i = 0; i < 8; i++) AddUnique(names, "vol" + i);

            // Create / reuse each double-buffered surface.
            for (int n = 0; n < names.Count; n++)
            {
                string name = names[n];
                ResolveSurfaceSize(graph, name, width, height, uniforms,
                    out int w, out int h, out string format);

                string readId = "global_" + name + "_read";
                string writeId = "global_" + name + "_write";

                // reuse-if-unchanged: preserves sim state across recompile/resize.
                RenderTexture existingRead = _store.Get(readId);
                if (existingRead != null &&
                    existingRead.width == w && existingRead.height == h)
                {
                    // keep both buffers; ensure record exists.
                    if (!_surfaces.ContainsKey(name))
                        _surfaces.Add(name, new SurfaceRecord
                        { Read = readId, Write = writeId, CurrentFrame = 0 });
                    continue;
                }
                _store.Destroy(readId);
                _store.Destroy(writeId);
                _store.CreateOrReuse(readId, w, h, format, false, 1);
                _store.CreateOrReuse(writeId, w, h, format, false, 1);
                _surfaces.Add(name, new SurfaceRecord
                { Read = readId, Write = writeId, CurrentFrame = 0 });
            }

            // Group 5: mesh0..mesh7 triplets — created once, never recreated on resize.
            for (int i = 0; i < 8; i++)
            {
                string name = "mesh" + i;
                if (_surfaces.ContainsKey(name)) continue;
                // Only allocate mesh surfaces actually referenced (avoid 8*3 unused
                // 256x256 rgba32f). A mesh-data input "meshN_positions" etc. flags it.
                if (!MeshReferenced(graph, i)) continue;
                string pos = "global_" + name + "_positions";
                string nor = "global_" + name + "_normals";
                string uv = "global_" + name + "_uvs";
                _store.CreateOrReuse(pos, MeshTexSize, MeshTexSize, "rgba32f", false, 1);
                _store.CreateOrReuse(nor, MeshTexSize, MeshTexSize, "rgba32f", false, 1);
                _store.CreateOrReuse(uv, MeshTexSize, MeshTexSize, "rgba32f", false, 1);
                _surfaces.Add(name, new SurfaceRecord
                {
                    IsMesh = true, Positions = pos, Normals = nor, Uvs = uv,
                    CurrentFrame = 0
                });
                // TODO(scope): mesh data upload (uploadMeshData / loadOBJ) and triangle
                // rendering path are out of scope for the first cut.
            }
        }

        private static bool MeshReferenced(RenderGraph graph, int meshIndex)
        {
            string prefix = "mesh" + meshIndex + "_";
            foreach (Pass pass in graph.Passes)
            {
                foreach (string v in pass.Inputs.Values)
                    if (v != null && v.IndexOf(prefix, System.StringComparison.Ordinal) >= 0)
                        return true;
                foreach (string v in pass.Outputs.Values)
                    if (v != null && v.IndexOf(prefix, System.StringComparison.Ordinal) >= 0)
                        return true;
            }
            return false;
        }

        private static void ScanGlobals(OrderedMap<string, string> map, List<string> into)
        {
            foreach (string texId in map.Values)
            {
                string name = ParseGlobalName(texId);
                if (name == null) continue;
                if (MeshDataPattern.IsMatch(name)) continue; // mesh-data handled in group 5
                AddUnique(into, name);
            }
        }

        private static void AddUnique(List<string> list, string v)
        {
            for (int i = 0; i < list.Count; i++) if (list[i] == v) return;
            list.Add(v);
        }

        // Resolve size+format for a surface: default W×H rgba16f, with group-specific
        // fixed sizes and graph global_<name> overrides.
        private void ResolveSurfaceSize(RenderGraph graph, string name,
            int width, int height, System.Func<string, double?> uniforms,
            out int w, out int h, out string format)
        {
            // group defaults
            if (name.StartsWith("vol", System.StringComparison.Ordinal))
            {
                w = VolumeSliceSize; h = VolumeAtlasHeight; format = "rgba16f";
            }
            else
            {
                w = Mathf.Max(1, width); h = Mathf.Max(1, height); format = "rgba16f";
            }

            // graph override: textures["global_<name>"] spec.
            TextureSpec spec;
            if (graph.Textures.TryGetValue("global_" + name, out spec) && spec != null)
            {
                if (spec.Width != null) w = TextureStore.ResolveDimension(spec.Width, width, uniforms);
                if (spec.Height != null) h = TextureStore.ResolveDimension(spec.Height, height, uniforms);
                if (!string.IsNullOrEmpty(spec.Format)) format = spec.Format;
            }
        }

        // ---- per-frame binding lifecycle ----------------------------------
        // reference §10 step 4: seed frameRead/frameWrite from surface.read/write.
        public void BeginFrame()
        {
            _frameRead.Clear();
            _frameWrite.Clear();
            // Index-based iteration avoids OrderedMap enumerator boxing per frame.
            int sc = _surfaces.Count;
            for (int i = 0; i < sc; i++)
            {
                var kv = _surfaces.EntryAt(i);
                SurfaceRecord rec = kv.Value;
                if (rec.IsMesh) continue;
                _frameRead[kv.Key] = rec.Read;
                _frameWrite[kv.Key] = rec.Write;
            }
        }

        // §10.2 within-frame ping-pong, applied after each executePass.
        public void UpdateFrameSurfaceBindings(Pass pass)
        {
            int oc = pass.Outputs.Count;
            for (int i = 0; i < oc; i++)
            {
                string outputTexId = pass.Outputs.EntryAt(i).Value;
                string name = ParseGlobalName(outputTexId);
                if (name == null) continue;
                if (!_surfaces.ContainsKey(name)) continue;

                // writeId = current write target for this surface
                string writeId;
                if (!_frameWrite.TryGetValue(name, out writeId)) continue;

                string currentReadId;
                _frameRead.TryGetValue(name, out currentReadId);

                // subsequent passes read the just-written texture
                _frameRead[name] = writeId;
                // next write goes to the old read buffer (ping-pong)
                if (currentReadId != null)
                    _frameWrite[name] = currentReadId;
            }
        }

        // §10.6 per-iteration swap (between iterations of a repeated pass).
        // PARITY (pipeline.js swapIterationBuffers): swap surface.read <-> surface.write
        // then set the frame maps FROM the swapped record (NOT from the prior frame-map
        // values). This makes the next iteration READ the texel just written (new
        // surface.read == old surface.write) and WRITE the buffer it just read from.
        // Setting the maps from the prior frame-map state instead desyncs repeated
        // sims (reactionDiffusion `simulate`, navierStokes `pressure`): the next
        // iteration would read stale state and overwrite the fresh result.
        public void SwapIterationBuffers(Pass pass)
        {
            int oc = pass.Outputs.Count;
            for (int i = 0; i < oc; i++)
            {
                string outputTexId = pass.Outputs.EntryAt(i).Value;
                string name = ParseGlobalName(outputTexId);
                if (name == null) continue;
                SurfaceRecord rec = GetSurface(name);
                if (rec == null) continue;
                // swap surface.read <-> surface.write.
                string tmp = rec.Read; rec.Read = rec.Write; rec.Write = tmp;
                // frame maps mirror the swapped record (reference reads surface.read/
                // surface.write AFTER the swap).
                _frameRead[name] = rec.Read;
                _frameWrite[name] = rec.Write;
            }
        }

        // §10.7 end-of-frame: persist state surfaces, swap display surfaces.
        public void SwapBuffers(int frameIndex)
        {
            int sc = _surfaces.Count;
            for (int i = 0; i < sc; i++)
            {
                var kv = _surfaces.EntryAt(i);
                string name = kv.Key;
                SurfaceRecord rec = kv.Value;
                if (rec.IsMesh) continue;
                rec.CurrentFrame = frameIndex;

                if (IsStateSurface(name))
                {
                    // persist final bindings (no swap) — sims continue from last buffers.
                    string fr, fw;
                    bool hasR = _frameRead.TryGetValue(name, out fr);
                    bool hasW = _frameWrite.TryGetValue(name, out fw);
                    if (hasR && hasW && fr != null && fw != null)
                    {
                        rec.Read = fr;
                        rec.Write = fw;
                    }
                }
                else
                {
                    // display surface: swap read <-> write.
                    string tmp = rec.Read; rec.Read = rec.Write; rec.Write = tmp;
                }
            }
        }

        public void DestroyAll()
        {
            // textures themselves are owned/destroyed by TextureStore; just clear records.
            var keys = new List<string>(_surfaces.Keys);
            // OrderedMap has no Remove; rebuild empty by creating a fresh one is not
            // possible (field readonly). Clear via reflection-free approach: we simply
            // leave records; TextureStore.DestroyAll frees GPU memory. The manager is
            // discarded with the pipeline.
            _frameRead.Clear();
            _frameWrite.Clear();
        }
    }
}
