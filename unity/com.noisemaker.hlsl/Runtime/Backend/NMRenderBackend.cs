// NMRenderBackend.cs — executes one render-graph Pass via a CommandBuffer.
//
// Mirrors reference/05 §12 (executePass control flow) and §15 (draw modes), the
// WebGL2 GPGPU model: every pass is a fullscreen-triangle fragment draw
// (DrawProcedural(Triangles,3)), MRT via SetRenderTarget with a color-buffer array,
// blend via material render-state, scatter via DrawProcedural(Points,count).
//
// Render-pipeline-agnostic: only CommandBuffer + Material/Shader are used (no SRP
// types), so it works under Built-in, URP and HDRP. The CommandBuffer is supplied
// and executed by NMPipeline.
//
// Input binding: a pass input sampler "samplerName" -> texId. "none" / null binds a
// transparent-black texture so a sampler is always valid. Inputs are set as global
// textures by their reference sampler name (the .shader declares `Texture2D <name>;
// SamplerState sampler_<name>;`), matching the GLSL named-uniform model.

using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using Noisemaker.Hlsl.Compiler.Graph;
using PassType = Noisemaker.Hlsl.Compiler.Graph.PassType; // disambiguate vs UnityEngine.Rendering.PassType

namespace Noisemaker.Hlsl
{
    // Resolves graph texIds (pooled phys_N, global surfaces, "none") to RenderTextures.
    public interface ITextureResolver
    {
        // Read-side: returns the RT to SAMPLE for a given input texId.
        RenderTexture ResolveRead(string texId);
        // Write-side: returns the RT to RENDER INTO for a given output texId.
        RenderTexture ResolveWrite(string texId);
    }

    public sealed class NMRenderBackend
    {
        private readonly NMShaderRegistry _registry;
        private readonly ITextureResolver _resolver;
        private readonly UniformBinder _binder;

        // Reused per-pass MPB. MRT color arrays are cached per arity so SetRenderTarget
        // (which requires an exact-length array) does not allocate per frame.
        private readonly MaterialPropertyBlock _mpb = new MaterialPropertyBlock();
        private readonly Dictionary<int, RenderTargetIdentifier[]> _mrtArrays =
            new Dictionary<int, RenderTargetIdentifier[]>();

        // A 1x1 transparent-black RT bound for "none" inputs.
        private RenderTexture _blackTex;

        // _NM_Resolution global id (UniformBinder owns the per-frame value; we override
        // it for the duration of a viewport/volume-write pass, then restore it so other
        // screen-resolution passes in the same CommandBuffer are unaffected).
        private static readonly int IdNmResolution = Shader.PropertyToID("_NM_Resolution");

        // Depth buffers for 3D mesh (triangles) passes, keyed by (w<<16|h). The
        // reference attaches a depth buffer per triangle draw and clears it (RTs are
        // created depth-less). Pooled by size to avoid per-frame allocation.
        private readonly Dictionary<long, RenderTexture> _depthBuffers =
            new Dictionary<long, RenderTexture>();

        public NMRenderBackend(NMShaderRegistry registry, ITextureResolver resolver,
            UniformBinder binder)
        {
            _registry = registry;
            _resolver = resolver;
            _binder = binder;
        }

        private RenderTexture BlackTex()
        {
            if (_blackTex == null)
            {
                _blackTex = new RenderTexture(1, 1, 0, RenderTextureFormat.ARGBHalf,
                    RenderTextureReadWrite.Linear);
                _blackTex.name = "NM_None";
                _blackTex.Create();
                // clear to transparent black
                var prev = RenderTexture.active;
                RenderTexture.active = _blackTex;
                GL.Clear(false, true, new Color(0f, 0f, 0f, 0f));
                RenderTexture.active = prev;
            }
            return _blackTex;
        }

        // executePass — render one pass into the CommandBuffer.
        // pointCountResolver supplies the dynamic count for drawMode:"points" when
        // countUniform is set (count = stateSize*stateSize per the points convention).
        public void ExecutePass(CommandBuffer cmd, Pass pass,
            System.Func<string, double?> uniformLookup)
        {
            Material mat = _registry.ResolveMaterial(pass);
            if (mat == null)
            {
                Debug.LogError("[Noisemaker] No shader for pass '" + pass.Id +
                    "' (" + NMShaderRegistry.ShaderNameForPass(pass) + ")");
                return;
            }
            int passIndex = _registry.ResolvePassIndex(pass);

            // ---- resolve outputs (MRT detection, reference/05 §12.4) ----
            int outputCount = pass.Outputs.Count;
            // drawBuffers > 1 OR >1 output key => MRT.
            bool isMRT = (pass.DrawBuffers.HasValue && pass.DrawBuffers.Value > 1)
                         || outputCount > 1;

            RenderTexture primary = null;

            // reference webgl2.js triangles branch: 3D mesh draws need a DEPTH buffer
            // attached (RTs are created with 0 depth bits) + a per-pass depth clear, with
            // the .shader supplying ZWrite On / ZTest LEqual / Cull Back. Billboards are
            // 2D additive scatters (no depth) so they stay depth-less.
            bool needsDepth = pass.DrawMode == "triangles";

            if (isMRT)
            {
                // MRT attachment slot i MUST map 1:1 to the fragment's SV_Target<i>
                // (outputs keyed "color","color1",... in INSERTION order). The color
                // array therefore must be DENSE from index 0 with NO holes — collapsing
                // a null output would shift later attachments into wrong slots and the
                // shader would write the wrong buffer. A null in the middle is a
                // malformed graph; bail rather than misalign.
                RenderTargetIdentifier[] colors = GetMrtArray(outputCount);
                bool hole = false;
                // Iterate by index (EntryAt) to avoid the OrderedMap.Values iterator
                // allocation in the per-frame loop.
                for (int oi = 0; oi < outputCount; oi++)
                {
                    string texId = pass.Outputs.EntryAt(oi).Value;
                    RenderTexture rt = _resolver.ResolveWrite(texId);
                    if (rt == null) { hole = true; break; }
                    if (primary == null) primary = rt; // depth comes from attachment 0
                    colors[oi] = new RenderTargetIdentifier(rt);
                }
                if (primary == null || hole)
                {
                    Debug.LogWarning("[Noisemaker] MRT pass '" + pass.Id +
                        "' has an unresolvable output (attachment hole); skipping.");
                    return;
                }
                // depth buffer comes from the primary (attachment 0) RT.
                cmd.SetRenderTarget(colors, new RenderTargetIdentifier(primary));
            }
            else
            {
                // single output: outputs.color ?? first output value
                string outId = pass.Outputs.GetOrDefault("color", null);
                if (outId == null && pass.Outputs.Count > 0)
                    outId = pass.Outputs.EntryAt(0).Value;
                primary = outId != null ? _resolver.ResolveWrite(outId) : null;
                if (primary == null)
                {
                    Debug.LogWarning("[Noisemaker] pass '" + pass.Id +
                        "' has no resolvable output; skipping.");
                    return;
                }
                if (needsDepth)
                {
                    RenderTexture depth = DepthBuffer(primary.width, primary.height);
                    cmd.SetRenderTarget(new RenderTargetIdentifier(primary),
                        new RenderTargetIdentifier(depth));
                }
                else
                {
                    cmd.SetRenderTarget(new RenderTargetIdentifier(primary));
                }
            }

            // ---- VOLUME-WRITE viewport override (reference/04 §10 Pass.viewport) ----
            // synth3d/filter3d generators render into the volume ATLAS region (e.g.
            // 64 x 4096), and need _NM_Resolution == the atlas dims so NM_FragCoord
            // (= uv * _NM_Resolution) maps the fullscreen UV onto integer atlas pixels ->
            // voxel (x = px.x, y = px.y%volSize, z = px.y/volSize). Set the cmd viewport to
            // the atlas rect AND override _NM_Resolution for this draw, restoring after so
            // screen-resolution passes in the same frame are unaffected. The atlas output
            // RT already has these exact dims (TextureStore atlas convention), so the
            // viewport normally equals primary.width/height; we still honor an explicit
            // viewport for parity with the reference (which sets gl.viewport per pass).
            bool hasViewport = pass.ViewportWidth != null || pass.ViewportHeight != null;
            if (hasViewport)
            {
                int vpW = pass.ViewportWidth != null
                    ? TextureStore.ResolveDimension(pass.ViewportWidth, primary.width, uniformLookup)
                    : primary.width;
                int vpH = pass.ViewportHeight != null
                    ? TextureStore.ResolveDimension(pass.ViewportHeight, primary.height, uniformLookup)
                    : primary.height;
                cmd.SetViewport(new Rect(0f, 0f, vpW, vpH));
                cmd.SetGlobalVector(IdNmResolution, new Vector4(vpW, vpH, 0f, 0f));
            }
            else
            {
                // PER-PASS TARGET RESOLUTION (reference parity). In webgl2 each pass does
                // gl.viewport(0,0,targetW,targetH) and binds `resolution` = the OUTPUT RT
                // size, so gl_FragCoord is target-relative. NM_FragCoord = uv *
                // _NM_Resolution must therefore use the render-target size, NOT the global
                // screen size set once per frame by SetEngineGlobals. Full-screen passes
                // (target == screen) are unaffected (primary dims == screen dims); low-res
                // state passes (reactionDiffusion/navierStokes/cellularAutomata/mnca render
                // into ~32x32 feedback textures) otherwise receive an N×-too-large
                // fragCoord, so per-texel hash seeding (hash(fragCoord+seed) > 0.99) and the
                // `resolution` macro both diverge — the sim never seeds and stays empty.
                cmd.SetGlobalVector(IdNmResolution,
                    new Vector4(primary.width, primary.height, 0f, 0f));
            }

            // ---- clear directive (reference: passes do NOT auto-clear; only an
            // explicit clear directive clears). For triangle/mesh draws the reference
            // ALWAYS clears the depth buffer for the pass (webgl2.js gl.clear(DEPTH_BIT))
            // so geometry depth-sorts correctly regardless of an explicit color clear. ----
            bool clearColor = pass.Clear != null && !pass.Clear.IsNull;
            if (clearColor || needsDepth)
                cmd.ClearRenderTarget(needsDepth, clearColor,
                    clearColor ? ClearColorOf(pass.Clear) : new Color(0f, 0f, 0f, 0f));

            // ---- bind inputs as global textures (named samplers) ----
            BindInputs(cmd, pass);

            // ---- per-pass uniforms onto reused MPB ----
            _mpb.Clear();
            _binder.BindPassUniforms(_mpb, pass);

            // ---- blend (reference/05 §14) ----
            // pass.Blend truthy => additive ONE,ONE (deposit/scatter into float
            // accumulation); default => disabled (source overwrites dest). In Unity
            // the blend state is authored in the effect .shader's pass (deposit
            // passes declare `Blend One One`, others `Blend Off`). We therefore rely
            // on the per-pass shader's baked blend state matching pass.Blend.
            // TODO(verify): confirm each generated deposit .shader sets Blend One One
            // for its drawMode:"points" pass; the Blend flag here is the source truth.

            // ---- draw ----
            // primary is the resolved attachment-0 RT (output dims for "auto"/"screen").
            MeshTopology topo;
            int vertexCount;
            ResolveDraw(pass, uniformLookup, primary, out topo, out vertexCount);

            cmd.DrawProcedural(Matrix4x4.identity, mat, passIndex, topo,
                vertexCount, 1, _mpb);

            // ---- restore _NM_Resolution + viewport after a viewport/volume-write pass ----
            // A subsequent raymarch CONSUMER (render3d/renderLit3d) runs at SCREEN
            // resolution and reads _NM_Resolution for its fragCoord/uv; leaving the atlas
            // dims set would corrupt its camera ray. ScreenResolution is the per-frame
            // engine value supplied by NMPipeline; restoring it here (same CommandBuffer,
            // in submission order) is sufficient. SetViewport(full RT) is implicit on the
            // next SetRenderTarget, but we reset it explicitly for safety.
            if (hasViewport)
            {
                cmd.SetGlobalVector(IdNmResolution,
                    new Vector4(ScreenWidth, ScreenHeight, 0f, 0f));
                // viewport resets with the next SetRenderTarget; nothing else needed.
            }
        }

        // Per-frame screen resolution, set by NMPipeline before executing passes. Used to
        // RESTORE _NM_Resolution after a viewport (volume-write) pass overrides it.
        public int ScreenWidth { get; set; }
        public int ScreenHeight { get; set; }

        // Blit src -> dst using the shared NMBlit shader (chain handoff / present /
        // copyTexture). reference/04: copyTexture is a straight blit.
        public void Blit(CommandBuffer cmd, RenderTexture src, RenderTexture dst)
        {
            // CommandBuffer.Blit with the blit material does a fullscreen copy.
            Material blit = _registry.ResolveMaterial(BlitPass);
            if (blit != null)
                cmd.Blit(src, dst, blit, 0);
            else
                cmd.Blit(src, dst);
        }

        // A synthetic blit pass for material resolution.
        private static readonly Pass BlitPass = new Pass
        { Id = "_nm_blit", PassType = PassType.Blit, Func = "blit", ProgName = null };

        // ---- helpers ------------------------------------------------------

        // A pooled depth-only RenderTexture sized w x h for 3D mesh passes. 24-bit depth
        // (RenderTextureFormat.Depth). The .shader supplies ZWrite/ZTest/Cull; this only
        // provides the attachment so depth testing has a target.
        private RenderTexture DepthBuffer(int w, int h)
        {
            w = Mathf.Max(1, w); h = Mathf.Max(1, h);
            long key = ((long)w << 32) | (uint)h;
            RenderTexture rt;
            if (_depthBuffers.TryGetValue(key, out rt) && rt != null) return rt;
            rt = new RenderTexture(w, h, 24, RenderTextureFormat.Depth,
                RenderTextureReadWrite.Linear);
            rt.name = "NM_Depth_" + w + "x" + h;
            rt.Create();
            _depthBuffers[key] = rt;
            return rt;
        }

        private RenderTargetIdentifier[] GetMrtArray(int n)
        {
            RenderTargetIdentifier[] arr;
            if (!_mrtArrays.TryGetValue(n, out arr))
            {
                arr = new RenderTargetIdentifier[n];
                _mrtArrays[n] = arr;
            }
            return arr;
        }

        private void BindInputs(CommandBuffer cmd, Pass pass)
        {
            // Index-based iteration avoids the OrderedMap enumerator boxing per frame.
            int count = pass.Inputs.Count;
            for (int i = 0; i < count; i++)
            {
                var kv = pass.Inputs.EntryAt(i);
                string samplerName = kv.Key;
                string texId = kv.Value;
                RenderTexture rt;
                if (texId == null || texId == "none")
                    rt = BlackTex();
                else
                    rt = _resolver.ResolveRead(texId);
                if (rt == null) rt = BlackTex();
                // Set as a global texture so the .shader's `Texture2D <samplerName>`
                // (and `_MainTex` for blit) resolves. Use SetGlobalTexture on the cmd.
                cmd.SetGlobalTexture(samplerName, rt);
            }
        }

        // reference/05 §15 + webgl2.js §points draw: resolve draw topology + vertex count.
        //   fullscreen (default): Triangles, 3 (the fullscreen triangle).
        //   points: Points, count. The COUNT resolution mirrors webgl2.js exactly:
        //     * numeric count            -> that literal count.
        //     * count "input"            -> refTex = inputs.xyzTex ?? inputs.inputTex,
        //                                   resolved to its RenderTexture; count = w*h
        //                                   (one point per state texel; the deposit draws
        //                                   stateSize*stateSize points because the state
        //                                   surface is stateSize x stateSize).
        //     * count "auto"/"screen"    -> output RT dims (primary) w*h, else 1.
        //     * countUniform "stateSize" -> (resolved uniform)^2 (one point per texel of a
        //                                   stateSize x stateSize cloud). The reference
        //                                   points path reads only `count`, but the
        //                                   normalized point effects (lenia) encode the
        //                                   square via countUniform; honor it here.
        //     * else                     -> 1000 (reference `pass.count || 1000`).
        private void ResolveDraw(Pass pass, System.Func<string, double?> uniformLookup,
            RenderTexture primary, out MeshTopology topo, out int vertexCount)
        {
            if (pass.DrawMode == "points")
            {
                topo = MeshTopology.Points;
                // points => one vertex per particle (the agent count).
                int count = ResolveParticleCount(pass, uniformLookup, primary);
                vertexCount = Mathf.Max(1, count);
                // TODO(verify): D3D/Unity has no GL point-sprite; the deposit VS must
                // emit a 1-pixel quad per point (reference/05 §15.1 HLSL HAZARD). The
                // .shader for points passes owns that emulation; here we issue the
                // Points topology with one vertex per particle to match the VS contract.
                // The VS Loads the agent state textures (xyzTex/rgbaTex), which are bound
                // as global Texture2D by BindInputs above (texelFetch / .Load by vertex_id).
                return;
            }

            if (pass.DrawMode == "billboards")
            {
                // reference webgl2.js §billboards: gl.drawArrays(TRIANGLES, 0, count*6).
                // Camera-facing quad per agent: 6 verts (2 triangles). The deposit VS
                // Loads agent xyz/rgba (one texel per agentIndex = vertexID/6), then
                // expands the 6 corner verts of the billboard quad (cornerIndex =
                // vertexID%6) in clip space. count = stateSize*stateSize (xyzTex dims).
                topo = MeshTopology.Triangles;
                int agents = ResolveParticleCount(pass, uniformLookup, primary);
                // Guard against int overflow at large clouds (2048^2 * 6 ~ 25.2M < 2^31,
                // safe; but clamp defensively).
                long verts = (long)Mathf.Max(1, agents) * 6L;
                vertexCount = verts > int.MaxValue ? int.MaxValue : (int)verts;
                // TODO(verify): the billboard .shader VS must compute agentIndex =
                // SV_VertexID/6 and cornerIndex = SV_VertexID%6 (matching the WGSL
                // vertex_index%6 corner table) and Y-flip clip to match the reference.
                return;
            }

            if (pass.DrawMode == "triangles")
            {
                // reference webgl2.js §triangles: gl.drawArrays(TRIANGLES, 0, count) where
                // count = meshPositions.width*height (one vertex per mesh-data texel via
                // SV_VertexID -> Texture2D.Load). Depth state (ZWrite/ZTest/Cull + depth
                // clear) is enabled in ExecutePass for this mode and baked in the .shader.
                topo = MeshTopology.Triangles;
                int count;
                if (!string.IsNullOrEmpty(pass.CountUniform))
                {
                    double? u = uniformLookup != null ? uniformLookup(pass.CountUniform) : null;
                    count = u.HasValue && u.Value > 0 ? (int)u.Value : 3;
                }
                else if (pass.Count.HasValue)
                {
                    count = pass.Count.Value;
                }
                else if (pass.CountMode == "input" || pass.CountMode == "auto")
                {
                    // mesh position texture dims (meshPositions ?? inputTex), else 1 tri.
                    RenderTexture refTex = ResolveMeshCountTex(pass);
                    count = (refTex != null && refTex.width > 0 && refTex.height > 0)
                        ? refTex.width * refTex.height
                        : 3;
                }
                else
                {
                    count = 3; // reference fallback: 1 triangle.
                }
                vertexCount = Mathf.Max(1, count);
                return;
            }

            // default fullscreen triangle (reference default-shaders.js).
            topo = MeshTopology.Triangles;
            vertexCount = 3;
        }

        // Resolve the AGENT count for a scatter (points / billboards). Shared so both
        // draw modes derive the same stateSize*stateSize count from the SAME state
        // texture (reference webgl2.js points + billboards branches are identical except
        // for the *6 verts/agent expansion, applied by the caller).
        //   * numeric count            -> that literal count.
        //   * count "input"            -> xyzTex ?? inputTex dims (w*h = stateSize^2).
        //   * count "auto"/"screen"    -> output (attachment-0) dims, else 1.
        //   * countUniform "stateSize" -> (resolved uniform)^2 (one agent per texel).
        //   * else                     -> 1000 (reference `pass.count || 1000`).
        private int ResolveParticleCount(Pass pass, System.Func<string, double?> uniformLookup,
            RenderTexture primary)
        {
            if (pass.Count.HasValue) return pass.Count.Value;
            if (pass.CountMode == "input")
            {
                RenderTexture refTex = ResolveCountInputTex(pass);
                return (refTex != null && refTex.width > 0 && refTex.height > 0)
                    ? refTex.width * refTex.height : 1;
            }
            if (pass.CountMode == "auto" || pass.CountMode == "screen")
            {
                return (primary != null && primary.width > 0 && primary.height > 0)
                    ? primary.width * primary.height : 1;
            }
            if (!string.IsNullOrEmpty(pass.CountUniform))
            {
                double? u = uniformLookup != null ? uniformLookup(pass.CountUniform) : null;
                // stateSize uniform absent -> dimension default (64) so the cloud draws.
                double side = u.HasValue ? u.Value : 64.0;
                return (int)(side * side);
            }
            return 1000; // reference default `pass.count || 1000`.
        }

        // For count "input": resolve the state texture the count is derived from.
        // Reference webgl2.js prefers inputs.xyzTex over inputs.inputTex. The texId is
        // resolved through the SAME read resolver used to bind inputs, so a
        // "global_xyz" -> the surface's current frame-read state RT (sized stateSize^2).
        private RenderTexture ResolveCountInputTex(Pass pass)
        {
            string texId = pass.Inputs.GetOrDefault("xyzTex", null);
            if (string.IsNullOrEmpty(texId) || texId == "none")
                texId = pass.Inputs.GetOrDefault("inputTex", null);
            if (string.IsNullOrEmpty(texId) || texId == "none") return null;
            return _resolver.ResolveRead(texId);
        }

        // For drawMode "triangles" (meshRender) count "input"/"auto": resolve the mesh
        // position texture (meshPositions ?? inputTex) whose dims give the vertex count
        // (reference webgl2.js triangles branch). 256x256 mesh data => 65536 verts.
        private RenderTexture ResolveMeshCountTex(Pass pass)
        {
            string texId = pass.Inputs.GetOrDefault("meshPositions", null);
            if (string.IsNullOrEmpty(texId) || texId == "none")
                texId = pass.Inputs.GetOrDefault("inputTex", null);
            if (string.IsNullOrEmpty(texId) || texId == "none") return null;
            return _resolver.ResolveRead(texId);
        }

        private static Color ClearColorOf(JsonValue clear)
        {
            // clear may be a bool/number/array; transparent black is the reference
            // default for clearTexture. If an array [r,g,b,a] is given, use it.
            if (clear != null && clear.Kind == JsonKind.Array)
            {
                var a = clear.AsArray;
                float r = a.Count > 0 && a[0].Kind == JsonKind.Number ? (float)a[0].AsNumber : 0f;
                float g = a.Count > 1 && a[1].Kind == JsonKind.Number ? (float)a[1].AsNumber : 0f;
                float b = a.Count > 2 && a[2].Kind == JsonKind.Number ? (float)a[2].AsNumber : 0f;
                float al = a.Count > 3 && a[3].Kind == JsonKind.Number ? (float)a[3].AsNumber : 0f;
                return new Color(r, g, b, al);
            }
            return new Color(0f, 0f, 0f, 0f);
        }

        public void Dispose()
        {
            foreach (var kv in _depthBuffers)
            {
                RenderTexture rt = kv.Value;
                if (rt == null) continue;
                rt.Release();
#if UNITY_EDITOR
                Object.DestroyImmediate(rt);
#else
                Object.Destroy(rt);
#endif
            }
            _depthBuffers.Clear();

            if (_blackTex != null)
            {
                _blackTex.Release();
#if UNITY_EDITOR
                Object.DestroyImmediate(_blackTex);
#else
                Object.Destroy(_blackTex);
#endif
                _blackTex = null;
            }
        }
    }
}
