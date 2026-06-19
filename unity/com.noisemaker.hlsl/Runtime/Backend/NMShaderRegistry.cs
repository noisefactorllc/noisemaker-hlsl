// NMShaderRegistry.cs — resolves a normalized graph Pass to a Unity Shader +
// pass index. Render-pipeline-agnostic (only uses UnityEngine.Shader).
//
// Reference: GRAPH-JSON-SCHEMA.md ("## Pass") — a pass carries (namespace, func)
// which map to a Unity Shader named "Noisemaker/<namespace>/<func>" (see
// NMBlit.shader => "Noisemaker/Blit", Solid.shader => "Noisemaker/synth/solid").
// progName selects WHICH pass within that multi-pass Shader (e.g. blur H vs V).
//
// Pass-index resolution strategy (in order):
//   1. If the SubShader pass carries a tag "NMProg" == progName -> that pass index
//      (FindPassTagValue). This is the explicit, authored mapping.
//   2. Else fall back to pass NAME == progName (Shader.FindPassName style; we scan
//      via FindPassTagValue against the "Name" using ShaderData is editor-only, so
//      at runtime we cache a name->index from a build-time convention: a single-pass
//      effect resolves to index 0).
//   3. Else index 0 (single-pass effects).
//
// Blit passes (PassType.Blit / func=="blit") resolve to the shared "Noisemaker/Blit".
//
// Caching: (shaderName) -> Shader and (shaderName,progName) -> int pass index, so
// no per-frame Shader.Find / string work. No per-frame allocations after warmup.

using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
using Noisemaker.Hlsl.Compiler.Graph;
using PassType = Noisemaker.Hlsl.Compiler.Graph.PassType; // disambiguate vs UnityEngine.Rendering.PassType

namespace Noisemaker.Hlsl
{
    public sealed class NMShaderRegistry
    {
        public const string ShaderPrefix = "Noisemaker/";
        public const string BlitShaderName = "Noisemaker/Blit";
        // Tag that an authored multi-pass shader sets per Pass to name its program.
        // e.g.  Tags { "NMProg" = "blurH" }  on the first pass.
        public const string ProgTag = "NMProg";

        private readonly Dictionary<string, Shader> _shaders =
            new Dictionary<string, Shader>();
        // key = shaderName + "" + progName  ->  pass index
        private readonly Dictionary<string, int> _passIndex =
            new Dictionary<string, int>();
        // Reusable Material per shader (avoids per-frame Material allocs).
        private readonly Dictionary<string, Material> _materials =
            new Dictionary<string, Material>();

        // Shader name for a pass. Blit passes share the single blit shader.
        public static string ShaderNameForPass(Pass pass)
        {
            if (pass.PassType == PassType.Blit ||
                (pass.Func != null && pass.Func == "blit"))
                return BlitShaderName;
            return ShaderPrefix + pass.Namespace + "/" + pass.Func;
        }

        // Optional external name->Shader resolver, checked BEFORE Shader.Find.
        // In editor batchmode Shader.Find cannot see package shaders that are not
        // always-included; the editor parity runner sets this to an AssetDatabase-
        // backed map. In a player build, add the shaders to "Always Included Shaders"
        // (or a Resources folder) so Shader.Find resolves them and this stays null.
        public static System.Func<string, Shader> ExternalResolver;

        // Resolve (and cache) the Shader for a pass. Returns null if not found
        // (the pipeline logs a clear error).
        public Shader ResolveShader(Pass pass)
        {
            string name = ShaderNameForPass(pass);
            Shader sh;
            if (_shaders.TryGetValue(name, out sh)) return sh;
            sh = ExternalResolver != null ? ExternalResolver(name) : null;
            if (sh == null) sh = Shader.Find(name);
            _shaders[name] = sh; // cache even nulls to avoid repeated Find
            return sh;
        }

        // Reusable Material wrapping the pass's shader. Built once per shader.
        public Material ResolveMaterial(Pass pass)
        {
            string name = ShaderNameForPass(pass);
            Material m;
            if (_materials.TryGetValue(name, out m) && m != null) return m;
            Shader sh = ResolveShader(pass);
            if (sh == null) return null;
            m = new Material(sh) { hideFlags = HideFlags.HideAndDontSave };
            _materials[name] = m;
            return m;
        }

        // Resolve the pass index within the shader for pass.ProgName.
        // CommandBuffer.DrawProcedural / Blit take an int shaderPass.
        public int ResolvePassIndex(Pass pass)
        {
            string prog = pass.ProgName;
            if (string.IsNullOrEmpty(prog)) return 0;
            Material mat = ResolveMaterial(pass);
            if (mat == null) return 0;

            string key = mat.shader.name + "|" + prog;
            int idx;
            if (_passIndex.TryGetValue(key, out idx)) return idx;

            // Primary: match the SubShader Pass "Name" (Material.FindPass is a runtime
            // API). Our multi-pass .shaders name each Pass after its progName (blurH/blurV).
            idx = mat.FindPass(prog);
            // Fallbacks: an explicit NMProg tag, else single-pass index 0.
            if (idx < 0) idx = FindPassTagValue(mat.shader, prog);
            if (idx < 0) idx = 0;
            _passIndex[key] = idx;
            return idx;
        }

        // Scan SubShader 0's passes for one whose ProgTag matches progName, returning
        // its index; -1 if none. FindPassTagValue(passIndex, tagName) reads a pass tag
        // at runtime (available on Shader since 2019). Falls back to 0 on -1.
        private static int FindPassTagValue(Shader sh, string progName)
        {
            int passCount = sh.passCount; // SubShader 0 active-variant pass count
            var tagId = new ShaderTagId(ProgTag);
            for (int i = 0; i < passCount; i++)
            {
                ShaderTagId val = sh.FindPassTagValue(i, tagId);
                // ShaderTagId.none has null name.
                if (val.name == progName) return i;
            }
            // No NMProg tag: single-pass effect -> index 0.
            // TODO(verify): authored multi-pass effects MUST set Tags{"NMProg"=...};
            // confirm against the .shader ports once they exist (none multi-pass yet).
            return 0;
        }

        public void Dispose()
        {
            foreach (var kv in _materials)
            {
                if (kv.Value != null)
                {
#if UNITY_EDITOR
                    Object.DestroyImmediate(kv.Value);
#else
                    Object.Destroy(kv.Value);
#endif
                }
            }
            _materials.Clear();
            _shaders.Clear();
            _passIndex.Clear();
        }
    }
}
