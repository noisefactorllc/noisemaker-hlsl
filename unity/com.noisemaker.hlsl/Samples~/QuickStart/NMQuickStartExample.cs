// NMQuickStartExample.cs — minimal end-to-end Noisemaker HLSL sample.
//
// Renders a bundled precompiled graph (NoiseGraph.json) to a RenderTexture and shows it
// on a Renderer's material. This is the recommended (verified) input path: a `GraphJson`
// TextAsset exported via tools/export-graph.mjs.
//
// Setup:
//   1. Project Settings ▸ Player ▸ Color Space = Linear  (required — Gamma renders wrong).
//   2. Create a Quad (GameObject ▸ 3D Object ▸ Quad) with an Unlit/Texture material.
//   3. Add this component, assign GraphJson = NoiseGraph.json (imported with this sample)
//      and Target = the Quad's Renderer. Press Play.
//
// (For a UI display instead, set a RawImage.texture = the NMRenderer.Output in your own
// script — RawImage is omitted here to avoid a uGUI dependency in the sample.)

using UnityEngine;

namespace Noisemaker.Hlsl.Samples
{
    [AddComponentMenu("Noisemaker/Samples/Quick Start Example")]
    public sealed class NMQuickStartExample : MonoBehaviour
    {
        [Tooltip("A Noisemaker graph.json imported as a TextAsset (e.g. the bundled NoiseGraph).")]
        public TextAsset GraphJson;

        [Tooltip("Renderer whose material.mainTexture receives the output (e.g. a Quad).")]
        public Renderer Target;

        [Min(16)] public int Width = 512;
        [Min(16)] public int Height = 512;

        private NMRenderer _nm;

        private void OnEnable()
        {
            if (GraphJson == null)
            {
                Debug.LogWarning("[NMQuickStart] Assign GraphJson (the bundled NoiseGraph.json, " +
                                 "or your own export from tools/export-graph.mjs).");
                return;
            }

            // NMRenderer is the package's host MonoBehaviour. One per GameObject.
            _nm = GetComponent<NMRenderer>();
            if (_nm == null) _nm = gameObject.AddComponent<NMRenderer>();

            _nm.GraphJson = GraphJson;     // precompiled-graph source (recommended/verified)
            _nm.RenderWidth = Width;
            _nm.RenderHeight = Height;
            _nm.Rebuild();                 // (re)build the pipeline after assigning a source
        }

        private void LateUpdate()
        {
            if (_nm == null || Target == null) return;

            // NMRenderer renders in its own LateUpdate; Output is recreated on resize, so
            // re-fetch it each frame rather than caching.
            RenderTexture tex = _nm.Output;
            if (tex != null && Target.material != null)
                Target.material.mainTexture = tex;
        }
    }
}
