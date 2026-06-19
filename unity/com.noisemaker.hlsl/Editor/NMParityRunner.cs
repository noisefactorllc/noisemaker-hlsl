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
            // Build the runtime pipeline, warm 8 deterministic frames (so feedback/
            // state surfaces settle), present renderSurface -> output, dispose.
            var pipeline = new NMPipeline(graph);
            pipeline.Init(size, size);
            for (int i = 0; i < 8; i++) pipeline.Render(normalizedTime);
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
