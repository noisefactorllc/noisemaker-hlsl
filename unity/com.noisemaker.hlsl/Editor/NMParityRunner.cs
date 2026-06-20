// NMParityRunner.cs — Unity Editor parity renderer.
//
// Renders a normalized render-graph (graph.json from tools/export-graph.mjs) — or
// a DSL string via the C# DslCompiler once the live frontend lands — to a PNG that
// parity/compare.py diffs against the JS golden PNG.
//
// It is BOTH a [MenuItem] (Noisemaker/Parity/Render Graph To PNG…) and a
// batchmode-callable static (NMParityRunner.RenderToPng) so CI can drive it:
//
//   Unity -batchmode -quit -projectPath <proj> \
//     -executeMethod Noisemaker.Hlsl.Editor.NMParityRunner.RenderFromCommandLine \
//     -nmGraph <graph.json> -nmOut <candidate.png> -nmSize 256 -nmTime 0.25
//
// Determinism: the seed is baked into the graph's uniforms (e.g. seed=1). Time is
// normalized 0..1 (reference/04 §6). We build the pipeline at the SAME size as the
// golden, advance to the SAME normalized frame, render into an ARGBHalf LINEAR
// RenderTexture, ReadPixels into a linear Texture2D, and EncodeToPNG.
//
// PARITY HAZARDS (must match parity/export-and-render.mjs):
//   * Color space: ARGBHalf + RenderTextureReadWrite.Linear; NEVER sRGB. The
//     golden quantises linear float -> 8-bit with NO gamma; we read the linear RT
//     the same way. Player/Editor color space must be Linear.
//   * Y orientation: the JS golden flips GL bottom-left origin to top-down PNG row
//     order. Unity's RenderTexture is top-left origin; ReadPixels gives top-down.
//     We therefore write WITHOUT an extra flip and reconcile any residual flip in
//     NMBlit (the single Y-flip point, ARCHITECTURE.md). // TODO(verify) against a
//     gradient golden once both PNGs exist; flip here if a vertical mirror appears.
//   * Premultiplied alpha (reference/04 §7, WebGPU path): if the golden was
//     rendered on the webgpu backend, match premultiplied alpha on present.
//
// NOTE: this file depends on the Runtime executor (NMPipeline + NMRenderBackend +
// SurfaceManager) which is staged (ARCHITECTURE.md "Status: built
// correct-by-construction; not yet compiled"). The graph-load + readback + encode
// path below is final; the pipeline build/advance calls are written against the
// planned NMPipeline API and marked // TODO(verify) where the runtime surface is
// not yet frozen. When the executor lands, only the BuildAndRender region needs to
// compile-check against the real method names.

using System;
using System.IO;
using UnityEditor;
using UnityEngine;
using Noisemaker.Hlsl.Compiler;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl.Editor
{
    public static class NMParityRunner
    {
        // ---- Editor menu entry --------------------------------------------------
        [MenuItem("Noisemaker/Parity/Render Graph To PNG…")]
        public static void RenderGraphToPngMenu()
        {
            string graphPath = EditorUtility.OpenFilePanel("Select graph.json", "", "json");
            if (string.IsNullOrEmpty(graphPath)) return;
            string outPath = EditorUtility.SaveFilePanel("Save candidate PNG", "",
                Path.GetFileNameWithoutExtension(graphPath) + ".candidate.png", "png");
            if (string.IsNullOrEmpty(outPath)) return;
            RenderToPng(graphPath, outPath, 256, 0.25f);
            Debug.Log($"[NMParity] wrote {outPath}");
        }

        // ---- Batchmode entry ----------------------------------------------------
        // Parses -nmGraph/-nmOut/-nmSize/-nmTime from the command line.
        public static void RenderFromCommandLine()
        {
            string graphPath = GetArg("-nmGraph");
            string outPath = GetArg("-nmOut");
            int size = ParseIntArg("-nmSize", 256);
            float time = ParseFloatArg("-nmTime", 0.25f);

            if (string.IsNullOrEmpty(graphPath) || string.IsNullOrEmpty(outPath))
            {
                Debug.LogError("[NMParity] -nmGraph and -nmOut are required.");
                EditorApplication.Exit(2);
                return;
            }

            try
            {
                RenderToPng(graphPath, outPath, size, time);
                Debug.Log($"[NMParity] wrote {outPath} ({size}x{size}, time={time})");
                EditorApplication.Exit(0);
            }
            catch (Exception e)
            {
                Debug.LogError($"[NMParity] FAILED: {e}");
                EditorApplication.Exit(1);
            }
        }

        // ---- Batch entry --------------------------------------------------------
        // Renders MANY graphs in ONE editor session (avoids ~25s startup per graph).
        // -nmManifest <file>: each non-empty line is "<graphJson>\t<outPng>".
        // -nmSize / -nmTime apply to all. Per-graph failures are logged (NM-BATCH
        // FAIL <graph>: <msg>) and do not abort the batch.
        public static void RenderBatchFromCommandLine()
        {
            string manifest = GetArg("-nmManifest");
            int size = ParseIntArg("-nmSize", 256);
            float time = ParseFloatArg("-nmTime", 0.25f);
            if (string.IsNullOrEmpty(manifest) || !File.Exists(manifest))
            {
                Debug.LogError("[NMParity] -nmManifest <file> is required.");
                EditorApplication.Exit(2);
                return;
            }
            int ok = 0, fail = 0;
            foreach (string raw in File.ReadAllLines(manifest))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                string[] parts = line.Split('\t');
                if (parts.Length < 2) continue;
                string graph = parts[0], outPng = parts[1];
                try { RenderToPng(graph, outPng, size, time); ok++; Debug.Log($"[NMParity] wrote {outPng}"); }
                catch (Exception e) { fail++; Debug.LogError($"NM-BATCH FAIL {graph}: {e.Message}"); }
            }
            Debug.Log($"[NMParity] batch done: {ok} ok, {fail} fail");
            EditorApplication.Exit(0);
        }

        // ---- Core ---------------------------------------------------------------
        public static void RenderToPng(string graphJsonPath, string outPngPath, int size, float normalizedTime)
        {
            if (PlayerSettings.colorSpace != ColorSpace.Linear)
            {
                Debug.LogWarning("[NMParity] Project color space is not Linear; parity requires Linear color " +
                                 "(textures are ARGBHalf linear, golden is NOT sRGB-encoded).");
            }

            PreloadPackageShaders();

            string json = File.ReadAllText(graphJsonPath);
            RenderGraph graph = RenderGraph.FromJson(json);   // real, available API
            if (graph == null) throw new Exception("RenderGraph.FromJson returned null");

            // Output RT: ARGBHalf, linear, square. This is the surface we read back.
            var output = new RenderTexture(size, size, 0, RenderTextureFormat.ARGBHalf,
                RenderTextureReadWrite.Linear)
            {
                name = "NMParityOutput",
                enableRandomWrite = false,
                useMipMap = false,
                autoGenerateMips = false,
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Clamp
            };
            output.Create();

            try
            {
                BuildAndRender(graph, output, size, normalizedTime);

                // Read back the LINEAR RT into a linear Texture2D.
                var prev = RenderTexture.active;
                RenderTexture.active = output;
                var tex = new Texture2D(size, size, TextureFormat.RGBAFloat, false, /*linear*/ true);
                tex.ReadPixels(new Rect(0, 0, size, size), 0, 0);
                tex.Apply(false);
                RenderTexture.active = prev;

                // Quantise linear float -> 8-bit (no gamma) to match the golden's
                // Math.round(v*255) on the linear float readback.
                var rgba32 = new Texture2D(size, size, TextureFormat.RGBA32, false, /*linear*/ true);
                var src = tex.GetPixels();
                var dst = new Color32[src.Length];
                for (int i = 0; i < src.Length; i++)
                {
                    dst[i] = new Color32(
                        ToByte(src[i].r), ToByte(src[i].g), ToByte(src[i].b), ToByte(src[i].a));
                }
                rgba32.SetPixels32(dst);
                rgba32.Apply(false);

                byte[] png = rgba32.EncodeToPNG();
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPngPath)));
                File.WriteAllBytes(outPngPath, png);

                UnityEngine.Object.DestroyImmediate(tex);
                UnityEngine.Object.DestroyImmediate(rgba32);
            }
            finally
            {
                output.Release();
                UnityEngine.Object.DestroyImmediate(output);
            }
        }

        // ---- Live DSL batch entry (C#-DSL path: compiler frontend + shader) -------
        // -nmManifest <file>: each non-empty line is "<dslPath>\t<outPng>". Compiles each
        // DSL via the C# DslCompiler (the SAME frontend the live demo uses), renders the
        // resulting graph, and writes the PNG. Compile failures log NM-DSL-FAIL and skip.
        public static void RenderDslBatchFromCommandLine()
        {
            string manifest = GetArg("-nmManifest");
            int size = ParseIntArg("-nmSize", 256);
            float time = ParseFloatArg("-nmTime", 0.25f);
            if (string.IsNullOrEmpty(manifest) || !File.Exists(manifest))
            {
                Debug.LogError("[NMParity] -nmManifest <file> is required.");
                EditorApplication.Exit(2);
                return;
            }

            PreloadPackageShaders();
            EffectRegistry reg = LoadRegistryFromPackage();

            int ok = 0, fail = 0;
            foreach (string raw in File.ReadAllLines(manifest))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                string[] parts = line.Split('\t');
                if (parts.Length < 2) continue;
                string dslPath = parts[0], outPng = parts[1];
                string name = Path.GetFileName(dslPath);
                try
                {
                    RenderGraph graph = DslCompiler.Compile(File.ReadAllText(dslPath), reg);
                    if (graph == null) { fail++; Debug.LogError("NM-DSL-FAIL " + name + ": compile returned null"); continue; }
                    RenderGraphToPng(graph, outPng, size, time);
                    ok++; Debug.Log("[NMParity] wrote " + outPng);
                }
                catch (CompileException ce)
                {
                    fail++;
                    string detail = "NM-DSL-FAIL " + name + ": " + ce.Message;
                    if (ce.Diagnostics != null)
                        foreach (Diagnostic d in ce.Diagnostics) detail += " | " + d.Code + " " + d.Message;
                    if (ce.ExpandErrors != null)
                        foreach (string er in ce.ExpandErrors) detail += " | expand: " + er;
                    Debug.LogError(detail);
                }
                catch (Exception e)
                {
                    fail++; Debug.LogError("NM-DSL-FAIL " + name + ": " + e.Message);
                }
            }
            Debug.Log("[NMParity] dsl batch done: " + ok + " ok, " + fail + " fail");
            EditorApplication.Exit(0);
        }

        // ---- TEMP DIAGNOSTIC: compile a DSL and dump the normalized graph JSON -----
        // -nmDsl <dslFile> -nmOut <jsonFile>. Render-free; used to diff the C#-compiled
        // graph (uniforms/texture sizing) against the reference export-graph oracle.
        public static void CompileDslDumpFromCommandLine()
        {
            string dslPath = GetArg("-nmDsl");
            string outPath = GetArg("-nmOut");
            if (string.IsNullOrEmpty(dslPath) || !File.Exists(dslPath) || string.IsNullOrEmpty(outPath))
            {
                Debug.LogError("[NMParity] -nmDsl <file> -nmOut <file> required.");
                EditorApplication.Exit(2);
                return;
            }
            try
            {
                EffectRegistry reg = LoadRegistryFromPackage();
                RenderGraph graph = DslCompiler.Compile(File.ReadAllText(dslPath), reg);
                File.WriteAllText(outPath, DslCompiler.ToNormalizedJson(graph));
                Debug.Log("[NMParity] dumped graph -> " + outPath);
                EditorApplication.Exit(0);
            }
            catch (Exception e)
            {
                Debug.LogError("[NMParity] dump failed: " + e);
                EditorApplication.Exit(1);
            }
        }

        // ---- TEMP DIAGNOSTIC: render N frames, dump a named texture's RAW float32 -----
        // -nmDsl <dsl> -nmTex <texId> -nmOut <f32> [-nmSize -nmTime -nmFrames -nmTimeStep].
        // Used to read the navierStokes VELOCITY state (global_ns_velocity_chain_1, .rg)
        // and compare it to the reference frame-by-frame (the dye display hides velocity).
        public static void DumpVelocityFromCommandLine()
        {
            string dslPath = GetArg("-nmDsl");
            string outPath = GetArg("-nmOut");
            string texId = GetArg("-nmTex") ?? "global_ns_velocity_chain_1";
            int size = ParseIntArg("-nmSize", 256);
            float time = ParseFloatArg("-nmTime", 0.25f);
            int frames = ParseIntArg("-nmFrames", 8);
            float timeStep = ParseFloatArg("-nmTimeStep", 0f);
            if (string.IsNullOrEmpty(dslPath) || !File.Exists(dslPath))
            { Debug.LogError("[NMVel] -nmDsl required"); EditorApplication.Exit(2); return; }
            try
            {
                PreloadPackageShaders();
                EffectRegistry reg = LoadRegistryFromPackage();
                RenderGraph graph = DslCompiler.Compile(File.ReadAllText(dslPath), reg);
                int logEvery = ParseIntArg("-nmLogEvery", 0);
                var pipe = new NMPipeline(graph);
                pipe.Init(size, size);
                for (int i = 0; i < frames; i++)
                {
                    pipe.Render(timeStep > 0f ? (time + i * timeStep) % 1f : time);
                    if (logEvery > 0 && (i + 1) % logEvery == 0)
                    {
                        RenderTexture mt = pipe.ResolveRead(texId);
                        if (mt != null)
                        {
                            RenderTexture pv = RenderTexture.active; RenderTexture.active = mt;
                            var mtex = new Texture2D(mt.width, mt.height, TextureFormat.RGBAFloat, false);
                            mtex.ReadPixels(new Rect(0, 0, mt.width, mt.height), 0, 0); mtex.Apply();
                            RenderTexture.active = pv;
                            Color[] mp = mtex.GetPixels(); float mx = 0f, sm = 0f;
                            for (int k = 0; k < mp.Length; k++) { float mg = Mathf.Sqrt(mp[k].r*mp[k].r + mp[k].g*mp[k].g); if (mg > mx) mx = mg; sm += mg; }
                            Debug.Log("[NMVel] frame " + (i+1) + " " + texId + " maxMag=" + mx.ToString("G6") + " meanMag=" + (sm/mp.Length).ToString("G6"));
                            UnityEngine.Object.DestroyImmediate(mtex);
                        }
                    }
                }
                RenderTexture rt = pipe.ResolveRead(texId);
                if (rt == null) { Debug.LogError("[NMVel] no texture " + texId); pipe.Dispose(); EditorApplication.Exit(1); return; }
                RenderTexture prev = RenderTexture.active;
                RenderTexture.active = rt;
                var tex = new Texture2D(rt.width, rt.height, TextureFormat.RGBAFloat, false);
                tex.ReadPixels(new Rect(0, 0, rt.width, rt.height), 0, 0); tex.Apply();
                RenderTexture.active = prev;
                Color[] px = tex.GetPixels();
                float maxMag = 0f, sumMag = 0f;
                for (int i = 0; i < px.Length; i++)
                { float m = Mathf.Sqrt(px[i].r * px[i].r + px[i].g * px[i].g); if (m > maxMag) maxMag = m; sumMag += m; }
                Debug.Log("[NMVel] " + texId + " " + rt.width + "x" + rt.height + " frames=" + frames +
                          " maxVelMag=" + maxMag.ToString("G6") + " meanVelMag=" + (sumMag / px.Length).ToString("G6"));
                if (!string.IsNullOrEmpty(outPath))
                {
                    float[] flat = new float[px.Length * 4];
                    for (int i = 0; i < px.Length; i++) { flat[i*4]=px[i].r; flat[i*4+1]=px[i].g; flat[i*4+2]=px[i].b; flat[i*4+3]=px[i].a; }
                    byte[] bytes = new byte[flat.Length * 4];
                    System.Buffer.BlockCopy(flat, 0, bytes, 0, bytes.Length);
                    File.WriteAllBytes(outPath, bytes);
                    Debug.Log("[NMVel] dumped float32 rgba -> " + outPath);
                }
                pipe.Dispose();
                EditorApplication.Exit(0);
            }
            catch (Exception e) { Debug.LogError("[NMVel] failed: " + e); EditorApplication.Exit(1); }
        }

        // ---- TEMP DIAGNOSTIC: render with advancing time, dump a PNG every K frames ----
        // -nmDsl <dsl> -nmOut <prefix> -nmFrames N -nmTimeStep T -nmSnapshotEvery K [-nmSize].
        // Writes <prefix>_f<frame>.png. Per-frame GPU sync (1px readback every 16 frames)
        // reproduces the live demo's per-frame-present sync, so the unsynced-batch GPU
        // artifact does NOT occur and any divergence captured is REAL.
        public static void RenderSnapshotsFromCommandLine()
        {
            string dslPath = GetArg("-nmDsl");
            string outPrefix = GetArg("-nmOut");
            int size = ParseIntArg("-nmSize", 256);
            float time = ParseFloatArg("-nmTime", 0f);
            int frames = ParseIntArg("-nmFrames", 1800);
            float timeStep = ParseFloatArg("-nmTimeStep", 0.0016666667f);
            int snapEvery = ParseIntArg("-nmSnapshotEvery", 300);
            if (string.IsNullOrEmpty(dslPath) || !File.Exists(dslPath) || string.IsNullOrEmpty(outPrefix))
            { Debug.LogError("[NMSnap] -nmDsl -nmOut required"); EditorApplication.Exit(2); return; }
            try
            {
                PreloadPackageShaders();
                EffectRegistry reg = LoadRegistryFromPackage();
                RenderGraph graph = DslCompiler.Compile(File.ReadAllText(dslPath), reg);
                var output = new RenderTexture(size, size, 0, RenderTextureFormat.ARGBHalf, RenderTextureReadWrite.Linear)
                { useMipMap = false, autoGenerateMips = false, filterMode = FilterMode.Bilinear, wrapMode = TextureWrapMode.Clamp };
                output.Create();
                var pipe = new NMPipeline(graph);
                pipe.Init(size, size);
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPrefix + "_x.png")));
                var sync1 = new Texture2D(1, 1, TextureFormat.RGBAFloat, false);
                for (int i = 0; i < frames; i++)
                {
                    pipe.Render(timeStep > 0f ? (time + i * timeStep) % 1f : time);
                    int fn = i + 1;
                    if (fn % 16 == 0) { RenderTexture o = pipe.GetOutput(); if (o != null) { RenderTexture pv = RenderTexture.active; RenderTexture.active = o; sync1.ReadPixels(new Rect(0,0,1,1),0,0); sync1.Apply(); RenderTexture.active = pv; } }
                    if (fn % snapEvery == 0)
                    {
                        pipe.PresentTo(output);
                        RenderTexture pv2 = RenderTexture.active; RenderTexture.active = output;
                        var tex = new Texture2D(size, size, TextureFormat.RGBAFloat, false, true);
                        tex.ReadPixels(new Rect(0, 0, size, size), 0, 0); tex.Apply(false);
                        RenderTexture.active = pv2;
                        var rgba = new Texture2D(size, size, TextureFormat.RGBA32, false, true);
                        var sp = tex.GetPixels(); var dst = new Color32[sp.Length];
                        for (int k = 0; k < sp.Length; k++) dst[k] = new Color32(ToByte(sp[k].r), ToByte(sp[k].g), ToByte(sp[k].b), ToByte(sp[k].a));
                        rgba.SetPixels32(dst); rgba.Apply(false);
                        File.WriteAllBytes(outPrefix + "_f" + fn + ".png", rgba.EncodeToPNG());
                        UnityEngine.Object.DestroyImmediate(tex); UnityEngine.Object.DestroyImmediate(rgba);
                        Debug.Log("[NMSnap] wrote " + outPrefix + "_f" + fn + ".png");
                    }
                }
                UnityEngine.Object.DestroyImmediate(sync1);
                pipe.Dispose(); UnityEngine.Object.DestroyImmediate(output);
                EditorApplication.Exit(0);
            }
            catch (Exception e) { Debug.LogError("[NMSnap] failed: " + e); EditorApplication.Exit(1); }
        }

        // Build an EffectRegistry from the package's shipped Effects/*.json (the converted
        // reference definitions). Mirrors canvas.js effect registration.
        private static EffectRegistry LoadRegistryFromPackage()
        {
            var reg = new EffectRegistry();
            string[] guids = AssetDatabase.FindAssets("t:TextAsset", new[] { "Packages/com.noisemaker.hlsl/Effects" });
            int n = 0;
            foreach (string g in guids)
            {
                string path = AssetDatabase.GUIDToAssetPath(g);
                if (!path.EndsWith(".json")) continue;
                TextAsset ta = AssetDatabase.LoadAssetAtPath<TextAsset>(path);
                if (ta == null || string.IsNullOrEmpty(ta.text)) continue;
                try { reg.Register(JsonValue.Parse(ta.text)); n++; }
                catch (Exception e) { Debug.LogWarning("[NMParity] skip " + path + ": " + e.Message); }
            }
            Debug.Log("[NMParity] registry loaded " + n + " effect defs.");
            return reg;
        }

        // Core render shared by the graph.json path and the DSL path: build the pipeline
        // from an in-memory RenderGraph, advance 8 frames, read back the LINEAR RT,
        // quantise to 8-bit (no gamma — matches the golden), encode PNG.
        public static void RenderGraphToPng(RenderGraph graph, string outPngPath, int size, float normalizedTime)
        {
            if (graph == null) throw new Exception("RenderGraphToPng: null graph");
            if (PlayerSettings.colorSpace != ColorSpace.Linear)
                Debug.LogWarning("[NMParity] Project color space is not Linear; parity requires Linear color.");

            var output = new RenderTexture(size, size, 0, RenderTextureFormat.ARGBHalf,
                RenderTextureReadWrite.Linear)
            {
                name = "NMParityOutput",
                enableRandomWrite = false,
                useMipMap = false,
                autoGenerateMips = false,
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Clamp
            };
            output.Create();
            try
            {
                BuildAndRender(graph, output, size, normalizedTime);

                var prev = RenderTexture.active;
                RenderTexture.active = output;
                var tex = new Texture2D(size, size, TextureFormat.RGBAFloat, false, /*linear*/ true);
                tex.ReadPixels(new Rect(0, 0, size, size), 0, 0);
                tex.Apply(false);
                RenderTexture.active = prev;

                var rgba32 = new Texture2D(size, size, TextureFormat.RGBA32, false, /*linear*/ true);
                var srcpx = tex.GetPixels();
                var dst = new Color32[srcpx.Length];
                for (int i = 0; i < srcpx.Length; i++)
                    dst[i] = new Color32(ToByte(srcpx[i].r), ToByte(srcpx[i].g), ToByte(srcpx[i].b), ToByte(srcpx[i].a));
                rgba32.SetPixels32(dst);
                rgba32.Apply(false);

                byte[] png = rgba32.EncodeToPNG();
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPngPath)));
                File.WriteAllBytes(outPngPath, png);

                UnityEngine.Object.DestroyImmediate(tex);
                UnityEngine.Object.DestroyImmediate(rgba32);
            }
            finally
            {
                output.Release();
                UnityEngine.Object.DestroyImmediate(output);
            }
        }

        // BuildAndRender: construct the runtime pipeline from the graph, advance it
        // to the normalized frame, and present into `output`.
        //
        // The Runtime executor (NMPipeline) is staged; the calls below are the
        // PLANNED runtime contract (mirrors reference/04 §6-§7 and ARCHITECTURE.md).
        // They are isolated here so that when the executor lands this is the only
        // region needing a compile-check. // TODO(verify): confirm the exact
        // NMPipeline ctor/Init/Render/Present signatures against the Runtime asmdef.
        // In batchmode, Shader.Find returns null for shaders not referenced by any
        // included asset/scene. Force-load every shader in the package so the runtime's
        // NMShaderRegistry.Shader.Find resolves "Noisemaker/<ns>/<func>" by name.
        private static void PreloadPackageShaders()
        {
            string[] guids = AssetDatabase.FindAssets("t:Shader", new[] { "Packages/com.noisemaker.hlsl" });
            var byName = new System.Collections.Generic.Dictionary<string, Shader>();
            foreach (string g in guids)
            {
                Shader sh = AssetDatabase.LoadAssetAtPath<Shader>(AssetDatabase.GUIDToAssetPath(g));
                if (sh != null) byName[sh.name] = sh;
            }
            // Shader.Find can't see package shaders in batchmode; resolve by name from
            // the AssetDatabase-loaded set instead.
            NMShaderRegistry.ExternalResolver = n =>
            {
                Shader s; return byName.TryGetValue(n, out s) ? s : null;
            };
            Debug.Log("[NMParity] registered " + byName.Count + "/" + guids.Length + " package shaders by name.");
        }

        private static void BuildAndRender(RenderGraph graph, RenderTexture output, int size, float normalizedTime)
        {
            // Build the runtime pipeline, warm N deterministic frames (so feedback/
            // state surfaces settle), present renderSurface -> output, dispose.
            // -nmFrames overrides the default 8 (for sustained sim stability checks).
            // -nmTimeStep > 0 ADVANCES normalized time per frame (matches the live demo's
            // animated input: normalized=(Time.time/dur)%1); 0 = fixed time (deterministic).
            int frames = ParseIntArg("-nmFrames", 8);
            float timeStep = ParseFloatArg("-nmTimeStep", 0f);
            // -nmSyncEvery K: force a CPU-GPU sync every K frames (a 1px readback). The
            // live demo presents each frame (an implicit per-frame sync); a tight unsynced
            // render loop here instead lets the RT pool recycle persistent state textures
            // over many frames, which collapses iterative sims to black (a HARNESS artifact,
            // not a sim bug). Syncing reproduces the live demo's per-frame-synced behaviour.
            int syncEvery = ParseIntArg("-nmSyncEvery", 0);
            var pipeline = new NMPipeline(graph);
            pipeline.Init(size, size);
            Texture2D sync1 = syncEvery > 0 ? new Texture2D(1, 1, TextureFormat.RGBAFloat, false) : null;
            for (int i = 0; i < frames; i++)
            {
                pipeline.Render(timeStep > 0f ? (normalizedTime + i * timeStep) % 1f : normalizedTime);
                if (sync1 != null && (i + 1) % syncEvery == 0)
                {
                    RenderTexture o = pipeline.GetOutput();
                    if (o != null) { RenderTexture pv = RenderTexture.active; RenderTexture.active = o; sync1.ReadPixels(new Rect(0, 0, 1, 1), 0, 0); sync1.Apply(); RenderTexture.active = pv; }
                }
            }
            if (sync1 != null) UnityEngine.Object.DestroyImmediate(sync1);
            pipeline.PresentTo(output);
            pipeline.Dispose();
        }

        private static byte ToByte(float linear01)
        {
            int v = Mathf.RoundToInt(Mathf.Clamp01(linear01) * 255f);
            return (byte)Mathf.Clamp(v, 0, 255);
        }

        // ---- command-line arg helpers ------------------------------------------
        private static string GetArg(string name)
        {
            var args = Environment.GetCommandLineArgs();
            for (int i = 0; i < args.Length - 1; i++)
                if (args[i] == name) return args[i + 1];
            return null;
        }

        private static int ParseIntArg(string name, int fallback)
        {
            var s = GetArg(name);
            return int.TryParse(s, out var v) ? v : fallback;
        }

        private static float ParseFloatArg(string name, float fallback)
        {
            var s = GetArg(name);
            return float.TryParse(s, System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : fallback;
        }
    }
}
