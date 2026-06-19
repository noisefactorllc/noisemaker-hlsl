// NMRenderer.cs — the host MonoBehaviour. Obtains a RenderGraph (from a graph.json
// TextAsset, or by compiling a DSL string), builds an NMPipeline, and renders one
// frame per LateUpdate into an output RenderTexture that any Material / Shader Graph
// samples as a Texture2D (ARCHITECTURE.md "Runtime RenderTexture").
//
// Render-pipeline-agnostic: NMPipeline executes a CommandBuffer via
// Graphics.ExecuteCommandBuffer, so this works under Built-in, URP and HDRP.
//
// Public API (host-facing):
//   RenderTexture Output           — current output (renderSurface's frame-read RT)
//   void SetUniform(string,object) — set a global uniform (number/bool/int)
//   void Resize(int,int)           — change render resolution
//   void Rebuild()                 — re-obtain the graph + pipeline (after source swap)
//
// Time model: reference time is NORMALIZED 0..1 and wraps per animation loop
// (reference/04 §10). We normalize wall time by AnimationDuration seconds.

using UnityEngine;
using Noisemaker.Hlsl.Compiler;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl
{
    [DisallowMultipleComponent]
    public sealed class NMRenderer : MonoBehaviour
    {
        [Header("Source (one of)")]
        [Tooltip("Normalized graph JSON (golden export or live C# Expander output).")]
        public TextAsset GraphJson;

        [TextArea(3, 12)]
        [Tooltip("DSL source; compiled at runtime via the C# Compiler if no GraphJson.")]
        public string Dsl;

        [Header("Live DSL effect definitions (only needed when compiling Dsl)")]
        [Tooltip("Effect definition JSON assets (the package's Effects/**/*.json). " +
                 "Required by the live DSL compiler; works in builds.")]
        public TextAsset[] EffectDefinitions;

        [Tooltip("Optional filesystem dir of Effects/**/*.json (Editor/dev only). " +
                 "Used when EffectDefinitions is empty.")]
        public string EffectsDirectory;

        [Header("Render target")]
        public int RenderWidth = 800;
        public int RenderHeight = 600;

        [Tooltip("Seconds per animation loop; normalized time = (Time.time / duration) % 1.")]
        public float AnimationDuration = 10f;

        [Tooltip("Advance time automatically each frame.")]
        public bool Animate = true;

        private NMPipeline _pipeline;
        private RenderGraph _graph;
        private EffectRegistry _registry;   // cached effect definitions for the live DSL path

        // The most recent output RT (renderSurface's freshest written content).
        public RenderTexture Output { get; private set; }

        public RenderGraph Graph { get { return _graph; } }
        public NMPipeline Pipeline { get { return _pipeline; } }

        private void OnEnable()
        {
            Rebuild();
        }

        private void OnDisable()
        {
            DisposePipeline();
        }

        // (Re)obtain the graph and build the pipeline.
        public void Rebuild()
        {
            DisposePipeline();

            _graph = ObtainGraph();
            if (_graph == null)
            {
                Debug.LogError("[Noisemaker] NMRenderer: no graph source (assign GraphJson or Dsl).");
                return;
            }

            _pipeline = new NMPipeline(_graph);
            _pipeline.Init(RenderWidth, RenderHeight);
        }

        private RenderGraph ObtainGraph()
        {
            if (GraphJson != null && !string.IsNullOrEmpty(GraphJson.text))
                return GraphLoader.FromJson(GraphJson.text);

            if (!string.IsNullOrEmpty(Dsl))
                return CompileDsl(Dsl);

            return null;
        }

        // Live DSL path: compile DSL -> RenderGraph via the C# frontend.
        // The frontend implements linear generator->filter->write/render chains over
        // the shipped effects; advanced DSL features are staged (see Compiler/Lang).
        // TODO(verify): not yet exercised against the golden export (no Unity/Node in
        // the authoring session) — validate via parity/ before relying on it.
        private RenderGraph CompileDsl(string dsl)
        {
            EffectRegistry reg = ResolveRegistry();
            if (reg == null)
            {
                Debug.LogError("[Noisemaker] Live DSL needs effect definitions. Assign " +
                    "EffectDefinitions (the package's Effects/**/*.json) or EffectsDirectory, " +
                    "or use a GraphJson exported via tools/export-graph.mjs.");
                return null;
            }
            try
            {
                return DslCompiler.Compile(dsl, reg);
            }
            catch (System.Exception e)
            {
                Debug.LogError("[Noisemaker] DSL compile failed: " + e.Message);
                return null;
            }
        }

        // Build (and cache) the effect registry from serialized TextAssets (build-safe)
        // or, failing that, a filesystem directory (Editor/dev).
        private EffectRegistry ResolveRegistry()
        {
            if (_registry != null) return _registry;

            if (EffectDefinitions != null && EffectDefinitions.Length > 0)
            {
                var reg = new EffectRegistry();
                foreach (TextAsset ta in EffectDefinitions)
                {
                    if (ta == null || string.IsNullOrEmpty(ta.text)) continue;
                    reg.Register(JsonValue.Parse(ta.text));
                }
                _registry = reg;
                return _registry;
            }

            if (!string.IsNullOrEmpty(EffectsDirectory) &&
                System.IO.Directory.Exists(EffectsDirectory))
            {
                _registry = EffectRegistry.LoadFromDirectory(EffectsDirectory);
                return _registry;
            }

            return null;
        }

        private void LateUpdate()
        {
            if (_pipeline == null) return;

            if (Animate)
            {
                float duration = Mathf.Max(0.0001f, AnimationDuration);
                float normalized = (Time.time / duration) % 1f;
                _pipeline.Render(normalized);
            }
            Output = _pipeline.GetOutput();
        }

        // Render a single explicit normalized-time frame (host-driven time).
        public void RenderFrame(float normalizedTime)
        {
            if (_pipeline == null) return;
            _pipeline.Render(normalizedTime);
            Output = _pipeline.GetOutput();
        }

        public void Resize(int width, int height)
        {
            RenderWidth = Mathf.Max(1, width);
            RenderHeight = Mathf.Max(1, height);
            if (_pipeline != null) _pipeline.Resize(RenderWidth, RenderHeight);
        }

        // Host uniform setter. Accepts float/double/int/bool; other types are ignored.
        public void SetUniform(string name, object value)
        {
            if (_pipeline == null || string.IsNullOrEmpty(name)) return;
            double d;
            if (value is float) d = (float)value;
            else if (value is double) d = (double)value;
            else if (value is int) d = (int)value;
            else if (value is bool) d = ((bool)value) ? 1.0 : 0.0;
            else
            {
                // TODO(scope): vector/array/string/automation-config uniforms via
                // SetUniform(object) not yet supported; numeric only for the first cut.
                Debug.LogWarning("[Noisemaker] SetUniform ignored non-numeric value for '" +
                    name + "'.");
                return;
            }
            _pipeline.SetUniform(name, d);
        }

        // ---- mesh loading (reference loadOBJ + uploadMeshData) -------------
        // Upload an OBJ TextAsset into a mesh surface ("mesh0".."mesh7"). The bundled
        // share/meshes/*.obj should be imported as TextAssets (rename .obj -> .obj.txt or
        // add an .obj ScriptedImporter) and assigned here / passed in. Build-safe.
        public int LoadMesh(string meshName, TextAsset obj)
        {
            if (_pipeline == null || obj == null || string.IsNullOrEmpty(obj.text))
                return 0;
            return _pipeline.LoadMeshObj(meshName, obj.text);
        }

        // Upload an OBJ from raw text (host already read the file).
        public int LoadMeshText(string meshName, string objText)
        {
            if (_pipeline == null || string.IsNullOrEmpty(objText)) return 0;
            return _pipeline.LoadMeshObj(meshName, objText);
        }

        // Editor/dev convenience: read an OBJ off disk (e.g. share/meshes/sphere.obj) and
        // upload it. Not build-safe (filesystem); use LoadMesh(TextAsset) in builds.
        public int LoadMeshFromFile(string meshName, string objPath)
        {
            if (_pipeline == null || string.IsNullOrEmpty(objPath) ||
                !System.IO.File.Exists(objPath)) return 0;
            return _pipeline.LoadMeshObj(meshName, System.IO.File.ReadAllText(objPath));
        }

        private void DisposePipeline()
        {
            if (_pipeline != null)
            {
                _pipeline.Dispose();
                _pipeline = null;
            }
            Output = null;
        }
    }
}
