// GraphLoader.cs — maps normalized graph JSON into the RenderGraph model.
//
// Implements the GRAPH-JSON-SCHEMA.md contract exactly. Pure C#, no UnityEngine.
//
// Distinctions preserved (reference/03 §9 hazard 5, reference/04 §9):
//   - "absent" (JSON key missing)   -> C# null / left at default
//   - JSON null                      -> kept as null where the field is nullable
//   - 0 / false                      -> valid values, NEVER treated as "missing"
// Numbers are read as double; schema-typed ints are cast via (int).
//
// Dim parsing follows reference/03 §2.4 variant detection (object branch keys:
// param > screenDivide > scale, checked in that order, matching resolveDimension).

using System;
using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler.Graph
{
    public static class GraphLoader
    {
        public static RenderGraph FromJson(string json)
        {
            return FromJsonValue(JsonValue.Parse(json));
        }

        public static RenderGraph FromJsonValue(JsonValue root)
        {
            if (root == null || root.Kind != JsonKind.Object)
                throw new FormatException("Render graph root must be a JSON object");

            var g = new RenderGraph
            {
                Id = GetString(root, "id"),
                Source = GetString(root, "source"),
                RenderSurface = GetString(root, "renderSurface")
            };

            // passes (ordered array)
            JsonValue passes = root.Get("passes");
            if (passes != null && passes.Kind == JsonKind.Array)
            {
                foreach (JsonValue p in passes.AsArray)
                    g.Passes.Add(ParsePass(p));
            }

            // allocations: texId -> "phys_N" (string)
            JsonValue alloc = root.Get("allocations");
            if (alloc != null && alloc.Kind == JsonKind.Object)
            {
                foreach (var kv in alloc.AsObject)
                    g.Allocations.Add(kv.Key, kv.Value.AsString);
            }

            // textures: texId -> TextureSpec
            JsonValue textures = root.Get("textures");
            if (textures != null && textures.Kind == JsonKind.Object)
            {
                foreach (var kv in textures.AsObject)
                    g.Textures.Add(kv.Key, ParseTextureSpec(kv.Value));
            }

            // programs: programId -> Program (optional)
            JsonValue programs = root.Get("programs");
            if (programs != null && programs.Kind == JsonKind.Object)
            {
                foreach (var kv in programs.AsObject)
                    g.Programs.Add(kv.Key, ParseProgram(kv.Value));
            }

            return g;
        }

        // ---- Pass ----------------------------------------------------------

        private static Pass ParsePass(JsonValue p)
        {
            if (p.Kind != JsonKind.Object)
                throw new FormatException("pass entry must be an object");

            var pass = new Pass
            {
                Id = GetString(p, "id"),
                PassType = ParsePassType(p),
                Namespace = GetString(p, "namespace"),
                Func = GetString(p, "func"),
                ProgName = GetString(p, "progName"),
                Program = GetString(p, "program"),
                DrawMode = GetString(p, "drawMode"),
                CountUniform = GetString(p, "countUniform"),
                EffectKey = GetString(p, "effectKey"),
                NodeId = GetString(p, "nodeId")
            };

            // defines: MACRO_NAME -> int
            JsonValue defines = p.Get("defines");
            if (defines != null && defines.Kind == JsonKind.Object)
            {
                foreach (var kv in defines.AsObject)
                    pass.Defines.Add(kv.Key, (int)kv.Value.AsNumber);
            }

            // inputs / outputs: name -> texId string
            CopyStringMap(p.Get("inputs"), pass.Inputs);
            CopyStringMap(p.Get("outputs"), pass.Outputs);

            // uniforms: name -> literal value
            JsonValue uniforms = p.Get("uniforms");
            if (uniforms != null && uniforms.Kind == JsonKind.Object)
            {
                foreach (var kv in uniforms.AsObject)
                    pass.Uniforms.Add(kv.Key, ParseUniformValue(kv.Value));
            }

            // uniformSpecs: name -> { min, max }
            JsonValue specs = p.Get("uniformSpecs");
            if (specs != null && specs.Kind == JsonKind.Object)
            {
                foreach (var kv in specs.AsObject)
                {
                    JsonValue s = kv.Value;
                    pass.UniformSpecs.Add(kv.Key, new UniformSpec
                    {
                        Min = GetNumber(s, "min", 0),
                        Max = GetNumber(s, "max", 100)
                    });
                }
            }

            // optional execution modifiers — absent stays null/false.
            // count may be a NUMBER (literal vertex count) OR a STRING mode
            // ("input"/"auto"/"screen") per reference webgl2.js points draw. A string
            // count is preserved in CountMode (GetNullableInt only accepts numbers and
            // would otherwise silently drop "input", collapsing the deposit to the 1000
            // default and scattering the wrong point count).
            JsonValue countVal = p.Get("count");
            if (countVal != null && countVal.Kind == JsonKind.Number)
                pass.Count = (int)countVal.AsNumber;
            else if (countVal != null && countVal.Kind == JsonKind.String)
                pass.CountMode = countVal.AsString;
            pass.DrawBuffers = GetNullableInt(p, "drawBuffers");
            // blend is "truthy" in the reference: a bool true, OR a non-empty blend-mode
            // array (["one","one"]) / string ("One One") all mean additive accumulation.
            // GetBool only matched the bool form and dropped the array form (dla),
            // leaving Blend=false. Treat any present non-null/non-false value as truthy.
            pass.Blend = IsTruthyBlend(p.Get("blend"));
            pass.Repeat = ParseRepeat(p.Get("repeat"));
            JsonValue clear = p.Get("clear");
            pass.Clear = (clear != null && clear.Kind != JsonKind.Null) ? clear : null;

            // metadata
            pass.StepIndex = GetNullableInt(p, "stepIndex");
            pass.InheritsVolumeSize = GetBool(p, "inheritsVolumeSize", false);

            // DSL LOOPS: optional loop-group tagging (absent -> 0 = not in a loop).
            int? loopGroup = GetNullableInt(p, "loopGroupId");
            if (loopGroup.HasValue) pass.LoopGroupId = loopGroup.Value;
            int? loopIters = GetNullableInt(p, "loopIterations");
            if (loopIters.HasValue) pass.LoopIterations = loopIters.Value;

            // VOLUME-WRITE viewport (synth3d/filter3d): pass.viewport = { width, height }
            // as Dims (e.g. { param: volumeSize } x { param: volumeSize, power: 2 } =
            // 64 x 4096 atlas). Drives NMRenderBackend's _NM_Resolution override so
            // NM_FragCoord recovers integer atlas-pixel -> voxel addressing. Absent ->
            // null (full-target screen resolution, the 2D-effect case).
            JsonValue viewport = p.Get("viewport");
            if (viewport != null && viewport.Kind == JsonKind.Object)
            {
                JsonValue vw = viewport.Get("width");
                JsonValue vh = viewport.Get("height");
                if (vw != null && vw.Kind != JsonKind.Null) pass.ViewportWidth = ParseDim(vw);
                if (vh != null && vh.Kind != JsonKind.Null) pass.ViewportHeight = ParseDim(vh);
            }

            JsonValue scoped = p.Get("scopedParams");
            if (scoped != null && scoped.Kind == JsonKind.Object)
            {
                pass.ScopedParams = new OrderedMap<string, string>();
                foreach (var kv in scoped.AsObject)
                    pass.ScopedParams.Add(kv.Key, kv.Value.AsString);
            }
            // JSON null / absent scopedParams -> leave null (schema: null when absent)

            return pass;
        }

        private static PassType ParsePassType(JsonValue p)
        {
            string t = GetString(p, "passType");
            if (t == null)
            {
                // reference effect passes omit a type; blit passes carry type:"render"
                // and the normalizer also sets passType. Fall back to func=="blit".
                string func = GetString(p, "func");
                return string.Equals(func, "blit", StringComparison.Ordinal)
                    ? PassType.Blit : PassType.Effect;
            }
            return string.Equals(t, "blit", StringComparison.Ordinal)
                ? PassType.Blit : PassType.Effect;
        }

        private static Repeat ParseRepeat(JsonValue r)
        {
            if (r == null || r.Kind == JsonKind.Null) return null;
            if (r.Kind == JsonKind.Number) return Repeat.FromCount((int)r.AsNumber);
            if (r.Kind == JsonKind.String) return Repeat.FromUniform(r.AsString);
            throw new FormatException("repeat must be a number or string");
        }

        private static UniformValue ParseUniformValue(JsonValue v)
        {
            switch (v.Kind)
            {
                case JsonKind.Null: return UniformValue.Null;
                case JsonKind.Bool: return UniformValue.Of(v.AsBool);
                case JsonKind.Number: return UniformValue.Of(v.AsNumber);
                case JsonKind.String: return UniformValue.Of(v.AsString);
                case JsonKind.Array:
                {
                    // vec2/3/4 or palette arrays: numeric arrays. If any element is
                    // non-numeric, fall back to preserving the raw object.
                    var arr = v.AsArray;
                    var nums = new List<double>(arr.Count);
                    bool allNumbers = true;
                    for (int i = 0; i < arr.Count; i++)
                    {
                        if (arr[i].Kind == JsonKind.Number) nums.Add(arr[i].AsNumber);
                        else { allNumbers = false; break; }
                    }
                    if (allNumbers) return UniformValue.Of(nums);
                    return UniformValue.OfObject(v);
                }
                case JsonKind.Object:
                    // automation config (Oscillator/Midi/Audio) or other structured
                    // value: preserve raw for the runtime UniformBinder.
                    return UniformValue.OfObject(v);
                default:
                    return UniformValue.Null;
            }
        }

        // ---- TextureSpec & Dim --------------------------------------------

        private static TextureSpec ParseTextureSpec(JsonValue s)
        {
            if (s.Kind != JsonKind.Object)
                throw new FormatException("texture spec must be an object");

            var spec = new TextureSpec
            {
                Width = ParseDim(s.Get("width")),
                Height = ParseDim(s.Get("height")),
                Is3D = GetBool(s, "is3D", false),
                Format = GetString(s, "format")   // null when absent (pipeline defaults)
            };
            JsonValue depth = s.Get("depth");
            if (depth != null && depth.Kind != JsonKind.Null)
                spec.Depth = ParseDim(depth);
            return spec;
        }

        // Dim variants per reference/03 §2.4 / reference/04 §9.
        public static Dim ParseDim(JsonValue d)
        {
            if (d == null || d.Kind == JsonKind.Null) return null;

            if (d.Kind == JsonKind.Number)
                return Dim.FromNumber(d.AsNumber);

            if (d.Kind == JsonKind.String)
            {
                string str = d.AsString;
                if (str == "screen" || str == "auto") return Dim.FromScreen();
                if (str.Length > 0 && str[str.Length - 1] == '%')
                {
                    // parseFloat semantics: numeric prefix before '%'.
                    string num = str.Substring(0, str.Length - 1);
                    return Dim.FromPercent(ParseDouble(num));
                }
                // Unknown string dim: treat as screen fallback (reference falls
                // through to screenSize for unrecognized specs).
                return Dim.FromScreen();
            }

            if (d.Kind == JsonKind.Object)
            {
                // Detection order mirrors resolveDimension: param, then screenDivide,
                // then scale.
                if (d.Has("param"))
                {
                    return Dim.FromParam(
                        d.Get("param").AsString,
                        GetNullableNumber(d, "paramDefault"),
                        GetNullableNumber(d, "multiply"),
                        GetNullableNumber(d, "power"),
                        GetNullableNumber(d, "default"));
                }
                if (d.Has("screenDivide"))
                {
                    return Dim.FromScreenDivide(
                        d.Get("screenDivide").AsString,
                        GetNullableNumber(d, "default"));
                }
                if (d.Has("scale"))
                {
                    double? cmin = null, cmax = null;
                    JsonValue clamp = d.Get("clamp");
                    if (clamp != null && clamp.Kind == JsonKind.Object)
                    {
                        cmin = GetNullableNumber(clamp, "min");
                        cmax = GetNullableNumber(clamp, "max");
                    }
                    return Dim.FromScale(d.Get("scale").AsNumber, cmin, cmax);
                }
            }

            // Unrecognized -> screen fallback (matches resolveDimension step 7).
            return Dim.FromScreen();
        }

        // ---- Program ------------------------------------------------------

        private static Program ParseProgram(JsonValue p)
        {
            var prog = new Program { Raw = p };
            if (p.Kind != JsonKind.Object) return prog;

            JsonValue layout = p.Get("uniformLayout");
            if (layout != null && layout.Kind == JsonKind.Object)
            {
                foreach (var kv in layout.AsObject)
                {
                    JsonValue slot = kv.Value;
                    if (slot.Kind != JsonKind.Object) continue;
                    prog.UniformLayout.Add(kv.Key, new UniformSlot
                    {
                        Slot = (int)GetNumber(slot, "slot", 0),
                        Components = GetString(slot, "components")
                    });
                }
            }

            JsonValue defines = p.Get("defines");
            if (defines != null && defines.Kind == JsonKind.Object)
            {
                foreach (var kv in defines.AsObject)
                {
                    if (kv.Value.Kind == JsonKind.Number)
                        prog.Defines.Add(kv.Key, (int)kv.Value.AsNumber);
                }
            }

            return prog;
        }

        // ---- helpers ------------------------------------------------------

        private static void CopyStringMap(JsonValue obj, OrderedMap<string, string> into)
        {
            if (obj == null || obj.Kind != JsonKind.Object) return;
            foreach (var kv in obj.AsObject)
                into.Add(kv.Key, kv.Value.IsNull ? null : kv.Value.AsString);
        }

        private static string GetString(JsonValue obj, string key)
        {
            JsonValue v = obj.Get(key);
            if (v == null || v.Kind == JsonKind.Null) return null;
            return v.AsString;
        }

        private static double GetNumber(JsonValue obj, string key, double fallback)
        {
            JsonValue v = obj.Get(key);
            return (v != null && v.Kind == JsonKind.Number) ? v.AsNumber : fallback;
        }

        private static double? GetNullableNumber(JsonValue obj, string key)
        {
            JsonValue v = obj.Get(key);
            if (v == null || v.Kind != JsonKind.Number) return null;
            return v.AsNumber;
        }

        private static int? GetNullableInt(JsonValue obj, string key)
        {
            JsonValue v = obj.Get(key);
            if (v == null || v.Kind != JsonKind.Number) return null;
            return (int)v.AsNumber;
        }

        private static bool GetBool(JsonValue obj, string key, bool fallback)
        {
            JsonValue v = obj.Get(key);
            return (v != null && v.Kind == JsonKind.Bool) ? v.AsBool : fallback;
        }

        // blend truthiness (reference: `if (pass.blend) { additive }`). JS truthiness:
        // bool true, any non-empty array (["one","one"]), any non-empty string
        // ("One One"), or a non-zero number. null / absent / false / empty / 0 => false.
        private static bool IsTruthyBlend(JsonValue v)
        {
            if (v == null) return false;
            switch (v.Kind)
            {
                case JsonKind.Bool: return v.AsBool;
                case JsonKind.Array: return v.AsArray.Count > 0;
                case JsonKind.String: return !string.IsNullOrEmpty(v.AsString);
                case JsonKind.Number: return v.AsNumber != 0.0;
                default: return false;
            }
        }

        private static double ParseDouble(string s)
        {
            return double.Parse(s,
                System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture);
        }
    }
}
