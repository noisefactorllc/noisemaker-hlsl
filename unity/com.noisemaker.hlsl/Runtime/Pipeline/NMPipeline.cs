// NMPipeline.cs — the per-frame executor. Ports reference/04 §10 (render(time))
// control flow EXACTLY: normalized 0..1 time, deltaTime wrap = 1/60/10,
// updateGlobalUniforms, per-frame frameRead/Write seeding, per-pass
// shouldSkipPass + resolveRepeatCount + iterate + within-frame ping-pong,
// present renderSurface, end-of-frame swapBuffers.
//
// "Compile programs" is a no-op in Unity (shaders are precompiled assets); init
// instead validates that the registry resolves a Shader for every pass.
//
// Texture resolution (ITextureResolver): graph texIds map to RenderTextures as:
//   * "global_<name>_read"/"_write" handled implicitly: a pass input "global_<name>"
//     resolves to the surface's CURRENT FRAME-READ texture; a pass output
//     "global_<name>" resolves to the surface's CURRENT FRAME-WRITE texture.
//   * "none"/null -> handled by the backend (black).
//   * other texIds -> the pooled phys_N RT via graph.allocations (else the texId RT).

using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl
{
    public sealed class NMPipeline : ITextureResolver
    {
        // Normalized wrap delta: one 60fps frame mapped onto a 10s loop (reference §10.2).
        private const float WrapDelta = 1f / 60f / 10f;

        public RenderGraph Graph { get; private set; }

        private readonly TextureStore _store;
        private readonly SurfaceManager _surfaces;
        private readonly NMShaderRegistry _registry;
        private readonly UniformBinder _binder;
        private readonly NMRenderBackend _backend;
        private readonly NMMeshData _meshData; // uploadMeshData path (mesh surfaces)

        private int _width, _height;
        public int Width { get { return _width; } }
        public int Height { get { return _height; } }

        public int FrameIndex { get; private set; }
        private float _lastTime;

        // Tile / scale state (tiled hi-res export). Defaults: no tiling.
        private Vector2? _tileOffset;
        private Vector2? _fullResolution;
        private float _renderScale = 1f;

        // Live global uniform values (mutable host-set + engine). Used for repeat
        // count resolution, conditions, and dimension param lookups.
        private readonly Dictionary<string, double> _globalUniforms =
            new Dictionary<string, double>();

        // Reused command buffer.
        private readonly CommandBuffer _cmd;

        // Cached uniform-lookup delegate (avoids a per-frame method-group allocation).
        private readonly System.Func<string, double?> _uniformLookup;

        public NMPipeline(RenderGraph graph)
        {
            Graph = graph;
            _store = new TextureStore();
            _surfaces = new SurfaceManager(_store);
            _registry = new NMShaderRegistry();
            _binder = new UniformBinder();
            _backend = new NMRenderBackend(_registry, this, _binder);
            _meshData = new NMMeshData(_store, _surfaces);
            _cmd = new CommandBuffer { name = "Noisemaker" };
            _uniformLookup = UniformLookup;
        }

        // ---- init / resize -------------------------------------------------
        public void Init(int width, int height)
        {
            ValidatePrograms();
            SeedScopedUniforms();
            Resize(width, height);
        }

        // Reference §13 setUniform fans scoped (_node_/_chain_) uniform variants into
        // the global uniform set. The Unity port binds per-pass uniforms for shaders but
        // does NOT fan out scoped variants to _globalUniforms, so chain-scoped SIZING
        // params (e.g. stateSize_node_2 sizing pointsEmit's xyz/vel/rgba state textures)
        // are unresolvable at surface-creation time and ResolveDimension falls back to a
        // wrong default (the agent state collapsed to 64x64 instead of stateSize=128).
        // Seed them from the graph's pass uniforms; scoped names are unique per node so
        // there is no cross-pass conflict.
        private void SeedScopedUniforms()
        {
            foreach (Pass pass in Graph.Passes)
            {
                int n = pass.Uniforms.Count;
                for (int i = 0; i < n; i++)
                {
                    var kv = pass.Uniforms.EntryAt(i);
                    string name = kv.Key;
                    if (name.IndexOf("_node_", System.StringComparison.Ordinal) < 0 &&
                        name.IndexOf("_chain_", System.StringComparison.Ordinal) < 0)
                        continue;
                    if (_globalUniforms.ContainsKey(name)) continue;
                    UniformValue v = kv.Value;
                    if (v.Kind == UniformValueKind.Number)
                        _globalUniforms[name] = v.Number;
                }
            }
        }

        // "compilePrograms" analog: Unity shaders are precompiled; just verify the
        // registry resolves a Shader for each unique pass (reference §7 dedupe).
        private void ValidatePrograms()
        {
            var seen = new HashSet<string>();
            foreach (Pass pass in Graph.Passes)
            {
                string name = NMShaderRegistry.ShaderNameForPass(pass);
                if (!seen.Add(name)) continue;
                Shader sh = _registry.ResolveShader(pass);
                if (sh == null)
                    Debug.LogError("[Noisemaker] Shader not found: " + name +
                        " (pass " + pass.Id + "). Ensure it is in a Resources/Always-" +
                        "Included list so Shader.Find resolves it at runtime.");
            }
        }

        public void Resize(int width, int height)
        {
            _width = Mathf.Max(1, width);
            _height = Mathf.Max(1, height);
            _store.SetScreenSize(_width, _height);
            _surfaces.CreateSurfaces(Graph, _width, _height, UniformLookup);
            _store.AllocatePooled(Graph, UniformLookup);
            // TODO(scope): initAsyncEffects (CPU texture generation) not ported.
        }

        // ---- host API: uniforms -------------------------------------------
        public void SetUniform(string name, double value)
        {
            // reference setUniform: cap stateSize to maxStateSize (2048).
            if (name == "stateSize" || name.StartsWith("stateSize_node_",
                System.StringComparison.Ordinal))
            {
                if (value > 2048.0)
                {
                    Debug.LogWarning("[Noisemaker] " + name + " capped to maxStateSize 2048.");
                    value = 2048.0;
                }
            }
            _globalUniforms[name] = value;

            // If any texture spec references this param, surfaces/pool must resize.
            if (DimensionReferencesParam(name))
            {
                _surfaces.CreateSurfaces(Graph, _width, _height, UniformLookup);
                _store.AllocatePooled(Graph, UniformLookup);
            }
            // TODO(scope): per-pass uniform fan-out (_node_/_chain_) and palette
            // expansion (reference §13 setUniform) not ported; the named uniform is
            // bound at the pass level from graph.uniforms.
        }

        // ---- host API: mesh loading (reference loadOBJ + uploadMeshData) ----
        // Parse an OBJ string and upload it into the named mesh surface ("mesh0".."mesh7").
        // The surface triplet must already be allocated (a pass references
        // global_<meshName>_positions, so SurfaceManager.CreateSurfaces created it).
        // Returns the uploaded vertex count (0 if the surface is missing). Call after
        // Init/Resize and before Render. Host resolves the OBJ text from the effect's
        // externalMesh / builtinMeshes path (e.g. share/meshes/sphere.obj) — that mapping
        // lives in the effect definition, not the normalized graph, so it is host-driven.
        public int LoadMeshObj(string meshName, string objText)
        {
            return _meshData.UploadObj(meshName, objText);
        }

        // Uploaded vertex count for a mesh surface (drives count:"input" sizing; the draw
        // count is meshPositions.width*height = 65536, with unused texels carrying w=0).
        public int GetMeshVertexCount(string meshName)
        {
            return _meshData.GetVertexCount(meshName);
        }

        private double? UniformLookup(string name)
        {
            double v;
            return _globalUniforms.TryGetValue(name, out v) ? (double?)v : null;
        }

        private bool DimensionReferencesParam(string name)
        {
            foreach (var kv in Graph.Textures)
            {
                TextureSpec s = kv.Value;
                if (s == null) continue;
                if (DimRefs(s.Width, name) || DimRefs(s.Height, name) ||
                    DimRefs(s.Depth, name)) return true;
            }
            return false;
        }

        private static bool DimRefs(Dim d, string name)
        {
            if (d == null) return false;
            if (d.Kind == DimKind.Param) return d.Param == name;
            if (d.Kind == DimKind.ScreenDivide) return d.ScreenDivide == name;
            return false;
        }

        // ---- per-frame render (reference/04 §10) --------------------------
        public void Render(float time)
        {
            // 2. deltaTime + wrap.
            float deltaTime = _lastTime > 0f ? time - _lastTime : 0f;
            if (deltaTime < 0f) deltaTime = WrapDelta; // time wrapped
            _lastTime = time;

            // 3. updateGlobalUniforms.
            float frX = _fullResolution.HasValue ? _fullResolution.Value.x : _width;
            float frY = _fullResolution.HasValue ? _fullResolution.Value.y : _height;
            float tX = _tileOffset.HasValue ? _tileOffset.Value.x : 0f;
            float tY = _tileOffset.HasValue ? _tileOffset.Value.y : 0f;
            _binder.SetEngineGlobals(_width, _height, frX, frY, tX, tY,
                time, deltaTime, _renderScale, FrameIndex);
            // Tell the backend the screen resolution so it can RESTORE _NM_Resolution
            // after a volume-write pass overrides it to the atlas dims (NMRenderBackend
            // viewport handling).
            _backend.ScreenWidth = _width;
            _backend.ScreenHeight = _height;
            // Per-frame normalized time for automation (oscillator) uniform evaluation
            // (reference/04 §10.4 / §11). Same value passed to Render(time).
            _backend.NormalizedTime = time;

            // 4. seed frameRead/frameWrite from surfaces.
            _surfaces.BeginFrame();

            // 6. execute passes in order.
            _cmd.Clear();
            for (int i = 0; i < Graph.Passes.Count; i++)
            {
                Pass pass = Graph.Passes[i];

                // DSL LOOPS: a contiguous run of passes sharing a non-zero LoopGroupId is
                // an iterated subchain bracket. Run the whole run N times, ping-ponging
                // its global outputs between iterations (reference/04 §10.6). The grouping
                // is contiguous by construction (the Expander tags passes only while inside
                // the bracket), so scan forward for the run end and iterate the block.
                if (pass.LoopGroupId != 0)
                {
                    i = ExecuteLoopBracket(i);
                    continue;
                }

                if (ShouldSkipPass(pass)) continue;

                int repeatCount = ResolveRepeatCount(pass);
                for (int iter = 0; iter < repeatCount; iter++)
                {
                    _backend.ExecutePass(_cmd, pass, _uniformLookup);
                    _surfaces.UpdateFrameSurfaceBindings(pass); // §10.2
                    if (repeatCount > 1)
                        _surfaces.SwapIterationBuffers(pass);   // §10.6
                }
            }

            // 8. present renderSurface -> nothing here; the output RT is the frame-read
            // texture of renderSurface. The Driver reads Output after Render.

            // execute the queued GPU work.
            Graphics.ExecuteCommandBuffer(_cmd);

            // 9. end-of-frame swap.
            _surfaces.SwapBuffers(FrameIndex);

            // 10.
            FrameIndex++;
        }

        // DSL LOOPS: execute one iterated subchain bracket starting at pass index
        // `start`. Returns the LAST pass index of the bracket (the caller's for-loop
        // then increments past it). The bracket is the maximal contiguous run of passes
        // with the same non-zero LoopGroupId; the whole run executes LoopIterations
        // times, ping-ponging its global outputs between iterations (reference/04 §10.6
        // swapIterationBuffers). Per-pass `repeat` still applies inside each iteration.
        // TODO(verify): no JS reference exists for subchain N-fold expansion (the JS
        // reference loops via loopBegin/loopEnd accumulator effects, not a bracket), so
        // the exact buffer holding the presented result after N iterations must be
        // validated against captured frames once a Unity runtime is available.
        private int ExecuteLoopBracket(int start)
        {
            int groupId = Graph.Passes[start].LoopGroupId;
            int end = start;
            while (end + 1 < Graph.Passes.Count && Graph.Passes[end + 1].LoopGroupId == groupId)
                end++;
            int loopIters = Mathf.Max(1, Graph.Passes[start].LoopIterations);

            for (int iter = 0; iter < loopIters; iter++)
            {
                for (int p = start; p <= end; p++)
                {
                    Pass lp = Graph.Passes[p];
                    if (ShouldSkipPass(lp)) continue;
                    int rc = ResolveRepeatCount(lp);
                    for (int r = 0; r < rc; r++)
                    {
                        _backend.ExecutePass(_cmd, lp, _uniformLookup);
                        _surfaces.UpdateFrameSurfaceBindings(lp); // §10.2
                        if (rc > 1)
                            _surfaces.SwapIterationBuffers(lp);   // §10.6 (inner repeat)
                    }
                }
                // Per-loop-iteration ping-pong: swap each global surface written by the
                // bracket so the next iteration reads this iteration's output. Skipped on
                // the last iteration so the post-loop chain and end-of-frame swap see the
                // final content in the current read buffer.
                if (iter < loopIters - 1)
                    for (int p = start; p <= end; p++)
                        _surfaces.SwapIterationBuffers(Graph.Passes[p]); // §10.6
            }
            return end;
        }

        // shouldSkipPass — reference §10.3. The C# graph model carries conditions
        // only implicitly (not in the normalized Pass yet). TODO(scope): when the
        // normalizer emits conditions, evaluate skipIf/runIf here against
        // _globalUniforms ?? pass.uniforms with strict typed equality.
        private bool ShouldSkipPass(Pass pass)
        {
            return false;
        }

        // resolveRepeatCount — reference §10.5.
        private int ResolveRepeatCount(Pass pass)
        {
            Repeat r = pass.Repeat;
            if (r == null) return 1;
            if (r.IsCount) return Mathf.Max(1, r.Count);
            // uniform-name: globalUniforms[name] ?? pass.uniforms[name]; floor; >=1.
            double? gu = UniformLookup(r.UniformName);
            if (gu.HasValue) return Mathf.Max(1, (int)System.Math.Floor(gu.Value));
            UniformValue uv;
            if (pass.Uniforms.TryGetValue(r.UniformName, out uv) &&
                uv.Kind == UniformValueKind.Number)
                return Mathf.Max(1, (int)System.Math.Floor(uv.Number));
            return 1;
        }

        // ---- ITextureResolver ---------------------------------------------
        // A pass input "global_<name>" samples the surface's CURRENT frame-read RT.
        public RenderTexture ResolveRead(string texId)
        {
            string surfName = SurfaceManager.ParseGlobalName(texId);
            if (surfName != null)
            {
                // mesh-data names resolve to the static triplet (read side).
                RenderTexture mesh = ResolveMeshTexture(surfName);
                if (mesh != null) return mesh;
                RenderTexture rt = _surfaces.GetFrameReadTexture(surfName);
                if (rt != null) return rt;
            }
            return ResolvePhysical(texId);
        }

        // A pass output "global_<name>" renders into the surface's CURRENT frame-write RT.
        public RenderTexture ResolveWrite(string texId)
        {
            string surfName = SurfaceManager.ParseGlobalName(texId);
            if (surfName != null)
            {
                RenderTexture mesh = ResolveMeshTexture(surfName);
                if (mesh != null) return mesh;
                string writeId = _surfaces.GetFrameWriteId(surfName);
                if (writeId != null)
                {
                    RenderTexture rt = _store.Get(writeId);
                    if (rt != null) return rt;
                }
            }
            return ResolvePhysical(texId);
        }

        // mesh-data triplet ids: "<meshN>_positions|normals|uvs".
        private RenderTexture ResolveMeshTexture(string surfName)
        {
            // mesh-data global names are like "meshN_positions"; surfName here is the
            // global suffix. Match meshN_ prefix directly.
            int underscore = surfName.IndexOf('_');
            if (underscore <= 0) return null;
            string meshName = surfName.Substring(0, underscore);
            string attr = surfName.Substring(underscore + 1);
            if (!meshName.StartsWith("mesh", System.StringComparison.Ordinal)) return null;
            SurfaceRecord rec = _surfaces.GetSurface(meshName);
            if (rec == null || !rec.IsMesh) return null;
            switch (attr)
            {
                case "positions": return _store.Get(rec.Positions);
                case "normals": return _store.Get(rec.Normals);
                case "uvs": return _store.Get(rec.Uvs);
                default: return null;
            }
        }

        // Pooled / non-global texId: map through graph.allocations to phys_N, else
        // use the texId directly (some specs are stored under their own id).
        //
        // POOLING ALIAS GUARD (reference parity): the JS liveness allocator
        // (resources.js) freely reuses a phys_N slot for texIds of DIFFERENT logical
        // sizes, but the JS WebGL2 runtime NEVER actually collapses to phys_N — it
        // allocates one real texture per VIRTUAL id at its own logical size
        // (pipeline.js recreateTextures keys by virtual texId). Our TextureStore pools
        // by phys_N at the MAX size across aliased virtuals. That is safe ONLY when the
        // aliased virtuals share dimensions; it BREAKS volume atlases (e.g.
        // node_0_volumeCache 64x4096 aliased with node_3_out screen 256x256 grows phys
        // to 256x4096): NM_FragCoord then spans the wrong width and fullscreen samplers
        // read by normalized UV across the oversized RT, scrambling the atlas. When this
        // texId's LOGICAL size differs from the pooled physical, fall back to the
        // reference behavior: a DEDICATED RT keyed by the virtual texId at logical size.
        private RenderTexture ResolvePhysical(string texId)
        {
            if (string.IsNullOrEmpty(texId) || texId == "none") return null;
            string phys;
            if (Graph.Allocations.TryGetValue(texId, out phys) && phys != null)
            {
                RenderTexture rt = _store.Get(phys);
                if (rt != null)
                {
                    // If this virtual's own logical size differs from the pooled physical
                    // RT, the alias is unsafe — use a dedicated logical-sized RT instead.
                    TextureSpec s;
                    if (Graph.Textures.TryGetValue(texId, out s) && s != null)
                    {
                        int lw = TextureStore.ResolveDimension(s.Width, _width, UniformLookup);
                        int lh = TextureStore.ResolveDimension(s.Height, _height, UniformLookup);
                        if (lw != rt.width || lh != rt.height)
                            return CreateLazyPhysical(texId, texId);
                    }
                    return rt;
                }
                // lazily create from the texId's spec.
                return CreateLazyPhysical(phys, texId);
            }
            RenderTexture direct = _store.Get(texId);
            if (direct != null) return direct;
            return CreateLazyPhysical(texId, texId);
        }

        private RenderTexture CreateLazyPhysical(string physId, string specTexId)
        {
            TextureSpec spec;
            if (!Graph.Textures.TryGetValue(specTexId, out spec) || spec == null)
                return null;
            int w = TextureStore.ResolveDimension(spec.Width, _width, UniformLookup);
            int h = TextureStore.ResolveDimension(spec.Height, _height, UniformLookup);
            int d = 1;
            if (spec.Is3D && spec.Depth != null)
                d = TextureStore.ResolveDimension(spec.Depth, _height, UniformLookup);
            return _store.CreateOrReuse(physId, w, h, spec.Format, spec.Is3D, d);
        }

        // ---- presentation / output ----------------------------------------
        // Output RT = the frame-read texture of renderSurface (freshest written
        // content), matching reference §10 step 8 presentId.
        public RenderTexture GetOutput()
        {
            if (string.IsNullOrEmpty(Graph.RenderSurface)) return null;
            return _surfaces.GetFrameReadTexture(Graph.RenderSurface);
        }

        public RenderTexture GetOutput(string surfaceName)
        {
            string name = string.IsNullOrEmpty(surfaceName) ? Graph.RenderSurface : surfaceName;
            if (string.IsNullOrEmpty(name)) return null;
            return _surfaces.GetFrameReadTexture(name);
        }

        // Blit the current renderSurface output into an external destination RT.
        // Used by NMParityRunner and host present paths. This is a STRAIGHT copy —
        // the single Y-flip reconciliation lives in NMBlit / NM_FLIP_Y (see
        // ARCHITECTURE.md), not here. Call after Render() for the freshest content.
        public void PresentTo(RenderTexture dst)
        {
            if (dst == null) return;
            RenderTexture src = GetOutput();
            if (src == null) return;
            Graphics.Blit(src, dst);
        }

        // ---- tiled export (data path present; logic TODO) -----------------
        public void SetTileRegion(Vector2 offset, Vector2 fullResolution, float renderScale)
        {
            _tileOffset = offset;
            _fullResolution = fullResolution;
            _renderScale = renderScale;
            // TODO(scope): tiled hi-res export full control flow not ported.
        }

        public void ClearTileRegion()
        {
            _tileOffset = null;
            _fullResolution = null;
            _renderScale = 1f;
        }

        public void SyncTime(float t) { _lastTime = t; }

        // ---- teardown ------------------------------------------------------
        public void Dispose()
        {
            _meshData.Dispose();
            _surfaces.DestroyAll();
            _store.DestroyAll();
            _backend.Dispose();
            _registry.Dispose();
            if (_cmd != null) _cmd.Release();
            _globalUniforms.Clear();
        }
    }
}
