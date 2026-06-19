// UniformBinder.cs — binds engine globals + per-pass named uniforms onto a reused
// MaterialPropertyBlock. Mirrors the named-uniform model in NMFullscreen.hlsl and
// reference/04 §10.1 (engine globals) + §10.4 (per-pass uniforms).
//
// Engine globals (set per frame, once, via Shader.SetGlobal* so every effect sees
// them through the NMFullscreen #define aliases):
//   _NM_Resolution (float4 .xy), _NM_FullResolution (.xy), _NM_TileOffset (.xy),
//   _NM_Time, _NM_DeltaTime, _NM_RenderScale, _NM_AspectRatio, _NM_Frame (int).
//
// Per-pass uniforms + define ints are written onto a single reused MPB
// (no per-frame allocation). Value kinds handled: number -> float, bool -> float
// (NMFullscreen tests `> 0.5`), int (defines) -> int, number array -> vec2/3/4.
// String uniforms are member-enum names already resolved to ints upstream; if a
// raw string survives it is skipped (cannot bind a string to a shader).

using UnityEngine;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl
{
    public sealed class UniformBinder
    {
        // METAL RESERVED-WORD remap. Unity's HLSL->Metal cross-compiler does NOT mangle
        // a uniform whose name is a Metal Shading Language keyword: e.g. a reference
        // uniform `kernel` (filter/edge) becomes `FGlobals.kernel` in the generated
        // Metal, where `kernel` is the compute-function qualifier -> "expected
        // unqualified-id" compile error -> the whole shader falls back to the error
        // shader -> the pass draws nothing (cleared target). We rename such names to a
        // Metal-safe form HERE (the single bind point) and the matching .hlsl declares
        // the same safe name. The reference/graph keep the canonical name; only the
        // Unity property name is translated. Keyed by canonical name; precomputed so
        // there is no per-bind string allocation. Add a keyword here ONLY when an
        // effect actually declares a uniform with that name (and rename it in the .hlsl).
        private static readonly System.Collections.Generic.Dictionary<string, string> MetalSafeNames =
            new System.Collections.Generic.Dictionary<string, string>
            {
                { "kernel", "kernel_u" },   // filter/edge
            };
        private static string SafeName(string name)
        {
            string safe;
            return MetalSafeNames.TryGetValue(name, out safe) ? safe : name;
        }

        // Cached shader property ids for engine globals.
        private static readonly int IdResolution     = Shader.PropertyToID("_NM_Resolution");
        private static readonly int IdFullResolution = Shader.PropertyToID("_NM_FullResolution");
        private static readonly int IdTileOffset      = Shader.PropertyToID("_NM_TileOffset");
        private static readonly int IdTime            = Shader.PropertyToID("_NM_Time");
        private static readonly int IdDeltaTime       = Shader.PropertyToID("_NM_DeltaTime");
        private static readonly int IdRenderScale     = Shader.PropertyToID("_NM_RenderScale");
        private static readonly int IdAspectRatio     = Shader.PropertyToID("_NM_AspectRatio");
        private static readonly int IdFrame           = Shader.PropertyToID("_NM_Frame");

        // Set the per-frame engine globals. Use SetGlobal* so the #define-aliased
        // bare names resolve in every effect shader regardless of MPB.
        public void SetEngineGlobals(int width, int height,
            float fullResX, float fullResY, float tileX, float tileY,
            float time, float deltaTime, float renderScale, int frame)
        {
            Shader.SetGlobalVector(IdResolution, new Vector4(width, height, 0f, 0f));
            Shader.SetGlobalVector(IdFullResolution, new Vector4(fullResX, fullResY, 0f, 0f));
            Shader.SetGlobalVector(IdTileOffset, new Vector4(tileX, tileY, 0f, 0f));
            Shader.SetGlobalFloat(IdTime, time);
            Shader.SetGlobalFloat(IdDeltaTime, deltaTime);
            Shader.SetGlobalFloat(IdRenderScale, renderScale);
            // aspectRatio alias is fullResolution.x/.y in NMFullscreen, but we also
            // expose the precomputed value for any shader binding it directly.
            float aspect = fullResY != 0f ? fullResX / fullResY : 1f;
            Shader.SetGlobalFloat(IdAspectRatio, aspect);
            Shader.SetGlobalInt(IdFrame, frame);
        }

        // Write a pass's resolved uniforms + define ints onto the reused MPB.
        // The MPB must be cleared by the caller (Clear()) before each pass to avoid
        // stale values bleeding across passes that omit a uniform.
        // normalizedTime is the 0..1 render time (reference/04 §10.4) used to evaluate
        // per-frame automation (oscillator) uniforms.
        public void BindPassUniforms(MaterialPropertyBlock mpb, Pass pass, float normalizedTime)
        {
            // Index-based iteration avoids the OrderedMap enumerator boxing per frame.
            // Define ints (compile-time consts bound as runtime ints; PORTING-GUIDE).
            int defCount = pass.Defines.Count;
            for (int di = 0; di < defCount; di++)
            {
                var d = pass.Defines.EntryAt(di);
                mpb.SetInt(SafeName(d.Key), d.Value);
            }

            // Named uniforms.
            int uCount = pass.Uniforms.Count;
            for (int ui = 0; ui < uCount; ui++)
            {
                var kv = pass.Uniforms.EntryAt(ui);
                string name = SafeName(kv.Key);
                UniformValue v = kv.Value;
                switch (v.Kind)
                {
                    case UniformValueKind.Number:
                        mpb.SetFloat(name, v.AsFloat);
                        break;
                    case UniformValueKind.Bool:
                        // NMFullscreen tests `> 0.5`; pass 1.0/0.0.
                        mpb.SetFloat(name, v.Bool ? 1f : 0f);
                        break;
                    case UniformValueKind.NumberArray:
                        BindVector(mpb, name, v.NumberArray);
                        break;
                    case UniformValueKind.String:
                        // Should be resolved to int upstream; cannot bind a string.
                        // TODO(verify): confirm normalizer resolves all member-enum
                        // names to numeric uniforms (reference/03 enum resolution).
                        break;
                    case UniformValueKind.Object:
                        // Automation config (Oscillator/Midi/Audio). Oscillators are
                        // evaluated per-frame (reference/04 §10.4 resolveUniformValue +
                        // §11). Midi/Audio fall back to the static value/min (out of scope).
                        BindAutomation(mpb, kv.Key, name, v.Object, pass, normalizedTime);
                        break;
                    case UniformValueKind.Null:
                    default:
                        break;
                }
            }
        }

        private static void BindVector(MaterialPropertyBlock mpb, string name,
            System.Collections.Generic.IReadOnlyList<double> arr)
        {
            if (arr == null || arr.Count == 0) return;
            float x = (float)arr[0];
            float y = arr.Count > 1 ? (float)arr[1] : 0f;
            float z = arr.Count > 2 ? (float)arr[2] : 0f;
            float w = arr.Count > 3 ? (float)arr[3] : 0f;
            mpb.SetVector(name, new Vector4(x, y, z, w));
        }

        // Automation binding (reference/04 §10.4 resolveUniformValue). For an Oscillator
        // config: pct = evaluateOscillator(cfg, normalizedTime); if a consumer paramSpec
        // exists, scale pct into [spec.min, spec.max], else bind pct directly. Midi/Audio
        // are out of scope and fall back to the static value/min. canonicalName is the
        // graph uniform key (used to look up pass.UniformSpecs); safeName is the Metal-
        // safe shader property name actually bound.
        private static void BindAutomation(MaterialPropertyBlock mpb,
            string canonicalName, string safeName, JsonValue cfg, Pass pass,
            float normalizedTime)
        {
            if (cfg == null || cfg.Kind != JsonKind.Object) return;
            JsonValue type = cfg.Get("type");
            if (type != null && type.Kind == JsonKind.String && type.AsString == "Oscillator")
            {
                double pct = Oscillators.Evaluate(cfg, normalizedTime);
                UniformSpec spec;
                if (pass.UniformSpecs != null &&
                    pass.UniformSpecs.TryGetValue(canonicalName, out spec))
                    pct = spec.Min + pct * (spec.Max - spec.Min);
                mpb.SetFloat(safeName, (float)pct);
                return;
            }
            // Non-oscillator automation (Midi/Audio): static fallback so a paused render
            // works — prefer an explicit numeric "value", else "min", else skip.
            JsonValue val = cfg.Get("value");
            if (val != null && val.Kind == JsonKind.Number)
            { mpb.SetFloat(safeName, (float)val.AsNumber); return; }
            JsonValue min = cfg.Get("min");
            if (min != null && min.Kind == JsonKind.Number)
            { mpb.SetFloat(safeName, (float)min.AsNumber); return; }
        }
    }
}
