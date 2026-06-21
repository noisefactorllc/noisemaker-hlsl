// NMShaderInclusionBuildStep.cs — make the package's runtime shaders survive a player build.
//
// THE PROBLEM: the runtime resolves every pass via Shader.Find("Noisemaker/<ns>/<func>")
// (NMShaderRegistry). Unity strips shaders that no scene/material references, so package
// shaders are absent from a player build and Shader.Find returns null → black output +
// "Shader not found". (NMShaderRegistry's own header notes the fix is to add them to
// Always Included Shaders or ship them in a Resources folder.)
//
// THE FIX (automatic, pipeline-agnostic): on build, add every "Noisemaker/*" shader to
// Project Settings ▸ Graphics ▸ Always Included Shaders, then remove exactly the ones we
// added once the build finishes — so the user's GraphicsSettings is left as it was.
// Always-Included shaders are compiled into the player regardless of render pipeline, so
// this works for Built-in, URP and HDRP alike.
//
// Editor-only (this asmdef is Editor-only). Runs only during a player build, so it does
// NOT affect in-editor play or the parity batchmode runs.

#if UNITY_EDITOR
using System.Collections.Generic;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;
using UnityEngine.Rendering;

namespace Noisemaker.Hlsl.Editor
{
    public sealed class NMShaderInclusionBuildStep : IPreprocessBuildWithReport, IPostprocessBuildWithReport
    {
        public int callbackOrder => 0;

        // Shaders we appended this build, to remove in postprocess (so we restore the
        // user's Always-Included list exactly). Null/empty when we added nothing.
        private static Shader[] _added;

        public void OnPreprocessBuild(BuildReport report)
        {
            _added = AddToAlwaysIncluded(CollectPackageShaders());
            if (_added.Length > 0)
                Debug.Log($"[Noisemaker] Build: added {_added.Length} 'Noisemaker/*' shaders to " +
                          "Always Included Shaders so the runtime resolves them in the player.");
        }

        public void OnPostprocessBuild(BuildReport report)
        {
            if (_added != null && _added.Length > 0)
                RemoveFromAlwaysIncluded(_added);
            _added = null;
        }

        // All runtime shaders ship as "Noisemaker/<ns>/<func>" (+ "Noisemaker/Blit"). The
        // Editor-only parity util "Hidden/Noisemaker/NMCubeEquirect" is intentionally NOT
        // matched (not used at runtime).
        public static Shader[] CollectPackageShaders()
        {
            var found = new List<Shader>();
            foreach (string guid in AssetDatabase.FindAssets("t:Shader", new[] { "Packages/com.noisemaker.hlsl" }))
            {
                Shader sh = AssetDatabase.LoadAssetAtPath<Shader>(AssetDatabase.GUIDToAssetPath(guid));
                if (sh != null && sh.name.StartsWith("Noisemaker/", System.StringComparison.Ordinal))
                    found.Add(sh);
            }
            return found.ToArray();
        }

        // Append any of `shaders` not already present. Returns exactly the ones added.
        public static Shader[] AddToAlwaysIncluded(Shader[] shaders)
        {
            var so = new SerializedObject(GraphicsSettings.GetGraphicsSettings());
            SerializedProperty arr = so.FindProperty("m_AlwaysIncludedShaders");

            var present = new HashSet<Shader>();
            for (int i = 0; i < arr.arraySize; i++)
            {
                var s = arr.GetArrayElementAtIndex(i).objectReferenceValue as Shader;
                if (s != null) present.Add(s);
            }

            var added = new List<Shader>();
            foreach (Shader sh in shaders)
            {
                if (sh == null || present.Contains(sh)) continue;
                int idx = arr.arraySize;
                arr.InsertArrayElementAtIndex(idx);
                arr.GetArrayElementAtIndex(idx).objectReferenceValue = sh;
                present.Add(sh);
                added.Add(sh);
            }
            if (added.Count > 0) so.ApplyModifiedProperties();
            return added.ToArray();
        }

        // Remove the given shaders from the Always-Included list (used to restore).
        public static void RemoveFromAlwaysIncluded(Shader[] shaders)
        {
            if (shaders == null || shaders.Length == 0) return;
            var remove = new HashSet<Shader>(shaders);
            var so = new SerializedObject(GraphicsSettings.GetGraphicsSettings());
            SerializedProperty arr = so.FindProperty("m_AlwaysIncludedShaders");
            bool changed = false;
            for (int i = arr.arraySize - 1; i >= 0; i--)
            {
                var s = arr.GetArrayElementAtIndex(i).objectReferenceValue as Shader;
                if (s != null && remove.Contains(s))
                {
                    // Null the slot first (DeleteArrayElementAtIndex on an object-ref array
                    // otherwise just clears the reference) then delete the (now-null) entry.
                    arr.GetArrayElementAtIndex(i).objectReferenceValue = null;
                    arr.DeleteArrayElementAtIndex(i);
                    changed = true;
                }
            }
            if (changed) so.ApplyModifiedProperties();
        }

        // ---- Manual / CI helpers ------------------------------------------------
        // Editor menu: permanently add the shaders (for users who prefer to manage the
        // list themselves rather than rely on the per-build step).
        [MenuItem("Noisemaker/Builds/Add shaders to Always Included")]
        public static void AddPermanently()
        {
            int n = AddToAlwaysIncluded(CollectPackageShaders()).Length;
            Debug.Log($"[Noisemaker] Added {n} shader(s) to Always Included Shaders (already-present ones skipped).");
        }

        // Batchmode self-test (no player build needed): collect → add → verify present →
        // restore → verify removed. Exits non-zero on failure.
        //   -executeMethod Noisemaker.Hlsl.Editor.NMShaderInclusionBuildStep.VerifyFromCommandLine
        public static void VerifyFromCommandLine()
        {
            try
            {
                Shader[] pkg = CollectPackageShaders();
                Debug.Log($"[NMShaderInclusion] collected {pkg.Length} 'Noisemaker/*' shaders.");
                if (pkg.Length == 0) { Debug.LogError("[NMShaderInclusion] FAIL: no package shaders found."); EditorApplication.Exit(1); return; }

                int before = AlwaysIncludedCount();
                Shader[] added = AddToAlwaysIncluded(pkg);
                int after = AlwaysIncludedCount();
                bool allPresent = AllPresent(pkg);
                Debug.Log($"[NMShaderInclusion] always-included {before} -> {after} (added {added.Length}); allPresent={allPresent}");

                RemoveFromAlwaysIncluded(added);
                int restored = AlwaysIncludedCount();
                Debug.Log($"[NMShaderInclusion] restored -> {restored}");

                bool ok = allPresent && restored == before;
                Debug.Log(ok ? "[NMShaderInclusion] PASS" : "[NMShaderInclusion] FAIL");
                EditorApplication.Exit(ok ? 0 : 1);
            }
            catch (System.Exception e)
            {
                Debug.LogError("[NMShaderInclusion] FAILED: " + e);
                EditorApplication.Exit(1);
            }
        }

        private static int AlwaysIncludedCount()
        {
            var so = new SerializedObject(GraphicsSettings.GetGraphicsSettings());
            return so.FindProperty("m_AlwaysIncludedShaders").arraySize;
        }

        private static bool AllPresent(Shader[] shaders)
        {
            var so = new SerializedObject(GraphicsSettings.GetGraphicsSettings());
            SerializedProperty arr = so.FindProperty("m_AlwaysIncludedShaders");
            var present = new HashSet<Shader>();
            for (int i = 0; i < arr.arraySize; i++)
            {
                var s = arr.GetArrayElementAtIndex(i).objectReferenceValue as Shader;
                if (s != null) present.Add(s);
            }
            foreach (Shader sh in shaders) if (!present.Contains(sh)) return false;
            return true;
        }
    }
}
#endif
