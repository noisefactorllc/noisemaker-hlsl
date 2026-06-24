// DslCompiler.cs — the public C# DSL frontend entry point.
//
// Ports shaders/src/runtime/compiler.js compileGraph: lex -> parse -> validate ->
// expand -> allocate -> assemble RenderGraph (the phase-1 graph model). Lets Unity
// render live from Polymorphic DSL source, validated later against the golden JS path.
//
// Pipeline (reference/01..04):
//   1. Lexer.Lex(src)                         -> tokens
//   2. Parser.Parse(tokens, registry)         -> ProgramNode AST
//   3. Validator.Validate(ast, registry)      -> ValidateResult { plans, diagnostics, render }
//      (errors are collected, not thrown, except missing-search; reference/02 H11)
//   4. Expander.Expand(validated, registry)   -> passes / programs / textureSpecs / renderSurface
//   5. Resources.AllocateResources(passes)    -> allocations (phys_N)
//   6. assemble RenderGraph (GRAPH-JSON-SCHEMA.md)
//
// compileGraph in JS THROWS on error-severity diagnostics or expansion errors; this port
// surfaces them via CompileException so callers can decide whether to render.
//
// Pure C#, no UnityEngine. Emits the Graph.RenderGraph model + ToNormalizedJson for
// golden diffing against tools/export-graph.mjs.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl.Compiler
{
    public sealed class CompileException : Exception
    {
        public List<Diagnostic> Diagnostics { get; }
        public List<string> ExpandErrors { get; }
        public CompileException(string message, List<Diagnostic> diags, List<string> expandErrors)
            : base(message)
        {
            Diagnostics = diags;
            ExpandErrors = expandErrors;
        }
    }

    public static class DslCompiler
    {
        // Compile DSL source into a RenderGraph. Throws DslSyntaxError on lex/parse errors,
        // CompileException on validator error-diagnostics or expansion errors (reference/02 §1.2).
        public static RenderGraph Compile(string dsl, EffectRegistry reg)
        {
            List<Token> tokens = Lexer.Lex(dsl);
            ProgramNode ast = Parser.Parse(tokens, reg);
            ValidateResult validated = Validator.Validate(ast, reg);

            // reference compiler.js: error-severity diagnostics abort compilation.
            var errors = new List<Diagnostic>();
            foreach (Diagnostic d in validated.Diagnostics)
                if (d.Severity == DiagnosticSeverity.Error) errors.Add(d);
            if (errors.Count > 0)
                throw new CompileException("ERR_COMPILATION_FAILED", validated.Diagnostics, null);

            ExpandResult expanded = Expander.Expand(validated, reg);
            if (expanded.Errors.Count > 0)
                throw new CompileException("ERR_EXPANSION_FAILED", null, expanded.Errors);

            OrderedMap<string, string> allocations = Resources.AllocateResources(expanded.Passes);

            var graph = new RenderGraph
            {
                Id = HashSource(dsl),
                Source = dsl,
                RenderSurface = expanded.RenderSurface,
                Passes = expanded.Passes,
                Programs = expanded.Programs,
                Allocations = allocations,
                Textures = BuildTextures(expanded)
            };
            return graph;
        }

        // extractTextureSpecs (compiler.js): start with expander textureSpecs (defaulting
        // width/height to 'screen', format to 'rgba16f'); then add pass output textures
        // that aren't already defined and aren't global_ (reference/04 §0 / compiler.js).
        private static OrderedMap<string, TextureSpec> BuildTextures(ExpandResult expanded)
        {
            var textures = new OrderedMap<string, TextureSpec>();
            foreach (var kv in expanded.TextureSpecs)
            {
                TextureSpec src = kv.Value;
                var spec = new TextureSpec
                {
                    Width = src.Width ?? Dim.FromScreen(),
                    Height = src.Height ?? Dim.FromScreen(),
                    Format = src.Format ?? "rgba16f",
                    Is3D = src.Is3D,
                    Depth = src.Depth
                };
                textures.Add(kv.Key, spec);
            }
            foreach (Pass pass in expanded.Passes)
            {
                foreach (string texId in pass.Outputs.Values)
                {
                    if (texId == null) continue;
                    if (texId.StartsWith("global_")) continue;
                    if (textures.ContainsKey(texId)) continue;
                    textures.Add(texId, new TextureSpec
                    {
                        Width = Dim.FromScreen(),
                        Height = Dim.FromScreen(),
                        Format = "rgba16f"
                    });
                }
            }
            return textures;
        }

        // hashSource (compiler.js): 32-bit ((h<<5)-h)+c rolling hash, base-36 string.
        // PARITY: JS `hash & hash` keeps it a signed 32-bit int; toString(36) on a
        // negative number yields a leading '-'. Replicate via unchecked int arithmetic.
        private static string HashSource(string source)
        {
            int hash = 0;
            for (int i = 0; i < source.Length; i++)
            {
                int ch = source[i];
                unchecked { hash = ((hash << 5) - hash) + ch; }
            }
            return ToBase36(hash);
        }

        private static string ToBase36(int value)
        {
            const string digits = "0123456789abcdefghijklmnopqrstuvwxyz";
            if (value == 0) return "0";
            bool negative = value < 0;
            // Use long to safely negate int.MinValue.
            long v = negative ? -(long)value : value;
            var sb = new StringBuilder();
            while (v > 0) { sb.Insert(0, digits[(int)(v % 36)]); v /= 36; }
            if (negative) sb.Insert(0, '-');
            return sb.ToString();
        }

        // --- normalized JSON serialization (golden diffing) -----------------

        // Serialize a RenderGraph to the normalized JSON (GRAPH-JSON-SCHEMA.md) for
        // byte-diffing against tools/export-graph.mjs (modulo compiledAt, which is omitted).
        // TODO(verify): diff this against the golden exporter output once buildable.
        public static string ToNormalizedJson(RenderGraph g)
        {
            var sb = new StringBuilder();
            sb.Append('{');
            WriteString(sb, "id", g.Id); sb.Append(',');
            WriteString(sb, "source", g.Source); sb.Append(',');
            WriteKey(sb, "renderSurface"); WriteJsonString(sb, g.RenderSurface); sb.Append(',');

            WriteKey(sb, "passes"); sb.Append('[');
            for (int i = 0; i < g.Passes.Count; i++)
            {
                if (i > 0) sb.Append(',');
                WritePass(sb, g.Passes[i]);
            }
            sb.Append(']'); sb.Append(',');

            WriteKey(sb, "allocations"); WriteStringMap(sb, g.Allocations); sb.Append(',');

            WriteKey(sb, "textures"); sb.Append('{');
            bool first = true;
            foreach (var kv in g.Textures)
            {
                if (!first) sb.Append(','); first = false;
                WriteKey(sb, kv.Key); WriteTextureSpec(sb, kv.Value);
            }
            sb.Append('}'); sb.Append(',');

            WriteKey(sb, "programs"); sb.Append('{');
            first = true;
            foreach (var kv in g.Programs)
            {
                if (!first) sb.Append(','); first = false;
                WriteKey(sb, kv.Key); WriteProgram(sb, kv.Value);
            }
            sb.Append('}');

            sb.Append('}');
            return sb.ToString();
        }

        private static void WritePass(StringBuilder sb, Pass p)
        {
            sb.Append('{');
            WriteString(sb, "id", p.Id); sb.Append(',');
            WriteString(sb, "passType", p.PassType == PassType.Blit ? "blit" : "effect"); sb.Append(',');
            WriteKey(sb, "namespace"); WriteJsonString(sb, p.Namespace); sb.Append(',');
            WriteString(sb, "func", p.Func); sb.Append(',');
            WriteKey(sb, "progName"); WriteJsonString(sb, p.ProgName); sb.Append(',');
            WriteString(sb, "program", p.Program); sb.Append(',');

            WriteKey(sb, "defines"); sb.Append('{');
            bool f = true;
            foreach (var kv in p.Defines) { if (!f) sb.Append(','); f = false; WriteKey(sb, kv.Key); sb.Append(kv.Value.ToString(CultureInfo.InvariantCulture)); }
            sb.Append('}'); sb.Append(',');

            WriteKey(sb, "inputs"); WriteStringMap(sb, p.Inputs); sb.Append(',');
            WriteKey(sb, "outputs"); WriteStringMap(sb, p.Outputs); sb.Append(',');

            WriteKey(sb, "uniforms"); sb.Append('{');
            f = true;
            foreach (var kv in p.Uniforms) { if (!f) sb.Append(','); f = false; WriteKey(sb, kv.Key); WriteUniform(sb, kv.Value); }
            sb.Append('}'); sb.Append(',');

            WriteKey(sb, "uniformSpecs"); sb.Append('{');
            f = true;
            foreach (var kv in p.UniformSpecs)
            {
                if (!f) sb.Append(','); f = false;
                WriteKey(sb, kv.Key); sb.Append('{');
                WriteKey(sb, "min"); sb.Append(JsNum(kv.Value.Min)); sb.Append(',');
                WriteKey(sb, "max"); sb.Append(JsNum(kv.Value.Max));
                sb.Append('}');
            }
            sb.Append('}');

            if (p.DrawMode != null) { sb.Append(','); WriteString(sb, "drawMode", p.DrawMode); }
            if (p.Count.HasValue) { sb.Append(','); WriteKey(sb, "count"); sb.Append(p.Count.Value); }
            if (p.CountUniform != null) { sb.Append(','); WriteString(sb, "countUniform", p.CountUniform); }
            if (p.DrawBuffers.HasValue) { sb.Append(','); WriteKey(sb, "drawBuffers"); sb.Append(p.DrawBuffers.Value); }
            // blend: emit the explicit two-factor array (["src","dst"]) when present
            // (matches the reference normalized graph, which passes the array through),
            // else the plain bool true for additive. Absent when not blending.
            if (p.BlendFactors != null && p.BlendFactors.Length == 2)
            {
                sb.Append(','); WriteKey(sb, "blend"); sb.Append('[');
                WriteJsonString(sb, p.BlendFactors[0]); sb.Append(',');
                WriteJsonString(sb, p.BlendFactors[1]); sb.Append(']');
            }
            else if (p.Blend) { sb.Append(','); WriteKey(sb, "blend"); sb.Append("true"); }
            // conditions: re-attached from the effect definition (reference exporter does
            // the same — the expander drops them). { runIf:[{uniform,equals}], skipIf:[...] }.
            if (p.Conditions != null) { sb.Append(','); WriteKey(sb, "conditions"); WriteConditions(sb, p.Conditions); }
            if (p.Repeat != null)
            {
                sb.Append(','); WriteKey(sb, "repeat");
                if (p.Repeat.IsCount) sb.Append(p.Repeat.Count);
                else WriteJsonString(sb, p.Repeat.UniformName);
            }
            // Always emit (null when absent) to match the reference normalized graph,
            // which emits effectKey/scopedParams unconditionally (export-graph normalizePass).
            sb.Append(','); WriteKey(sb, "effectKey"); WriteJsonString(sb, p.EffectKey);
            if (p.NodeId != null) { sb.Append(','); WriteString(sb, "nodeId", p.NodeId); }
            if (p.StepIndex.HasValue) { sb.Append(','); WriteKey(sb, "stepIndex"); sb.Append(p.StepIndex.Value); }
            if (p.InheritsVolumeSize) { sb.Append(','); WriteKey(sb, "inheritsVolumeSize"); sb.Append("true"); }
            sb.Append(','); WriteKey(sb, "scopedParams");
            if (p.ScopedParams != null) WriteStringMap(sb, p.ScopedParams); else sb.Append("null");
            // DSL LOOPS: emit loop-group tagging only when set (0 = none), round-tripped
            // by GraphLoader.ReadPass.
            if (p.LoopGroupId != 0)
            {
                sb.Append(','); WriteKey(sb, "loopGroupId"); sb.Append(p.LoopGroupId);
                sb.Append(','); WriteKey(sb, "loopIterations"); sb.Append(p.LoopIterations);
            }
            sb.Append('}');
        }

        // Serialize pass conditions { runIf:[{uniform,equals}], skipIf:[...] } to match
        // the reference normalized graph. Each list is omitted when null.
        private static void WriteConditions(StringBuilder sb, PassConditions c)
        {
            sb.Append('{');
            bool wrote = false;
            if (c.RunIf != null)
            {
                WriteKey(sb, "runIf"); WriteConditionList(sb, c.RunIf);
                wrote = true;
            }
            if (c.SkipIf != null)
            {
                if (wrote) sb.Append(',');
                WriteKey(sb, "skipIf"); WriteConditionList(sb, c.SkipIf);
            }
            sb.Append('}');
        }

        private static void WriteConditionList(StringBuilder sb, System.Collections.Generic.List<PassCondition> list)
        {
            sb.Append('[');
            for (int i = 0; i < list.Count; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append('{');
                WriteKey(sb, "uniform"); WriteJsonString(sb, list[i].Uniform); sb.Append(',');
                WriteKey(sb, "equals"); sb.Append(JsNum(list[i].EqualsValue));
                sb.Append('}');
            }
            sb.Append(']');
        }

        private static void WriteProgram(StringBuilder sb, Program prog)
        {
            sb.Append('{');
            WriteKey(sb, "uniformLayout"); sb.Append('{');
            bool f = true;
            foreach (var kv in prog.UniformLayout)
            {
                if (!f) sb.Append(','); f = false;
                WriteKey(sb, kv.Key); sb.Append('{');
                WriteKey(sb, "slot"); sb.Append(kv.Value.Slot); sb.Append(',');
                WriteKey(sb, "components"); WriteJsonString(sb, kv.Value.Components);
                sb.Append('}');
            }
            sb.Append('}'); sb.Append(',');
            WriteKey(sb, "defines"); sb.Append('{');
            f = true;
            foreach (var kv in prog.Defines) { if (!f) sb.Append(','); f = false; WriteKey(sb, kv.Key); sb.Append(kv.Value); }
            sb.Append('}');
            sb.Append('}');
        }

        private static void WriteTextureSpec(StringBuilder sb, TextureSpec t)
        {
            // Field order + usage mirror the reference compiler.js: width, height, format,
            // usage, [depth], [is3D]. Render textures get the render usage set; is3D (WebGPU
            // volume) textures get the storage set. format defaults to rgba16f.
            sb.Append('{');
            WriteKey(sb, "width"); WriteDim(sb, t.Width); sb.Append(',');
            WriteKey(sb, "height"); WriteDim(sb, t.Height); sb.Append(',');
            WriteString(sb, "format", t.Format ?? "rgba16f"); sb.Append(',');
            WriteKey(sb, "usage"); sb.Append(t.Is3D
                ? "[\"storage\",\"sample\",\"copySrc\",\"copyDst\"]"
                : "[\"render\",\"sample\",\"copySrc\",\"copyDst\"]");
            if (t.Depth != null) { sb.Append(','); WriteKey(sb, "depth"); WriteDim(sb, t.Depth); }
            if (t.Is3D) { sb.Append(','); WriteKey(sb, "is3D"); sb.Append("true"); }
            sb.Append('}');
        }

        private static void WriteDim(StringBuilder sb, Dim d)
        {
            if (d == null) { sb.Append("null"); return; }
            switch (d.Kind)
            {
                case DimKind.Number: sb.Append(JsNum(d.Number)); break;
                case DimKind.Screen: WriteJsonString(sb, d.ScreenLiteral ?? "screen"); break;
                case DimKind.Percent: WriteJsonString(sb, JsNum(d.Percent) + "%"); break;
                case DimKind.Param:
                    sb.Append('{'); WriteKey(sb, "param"); WriteJsonString(sb, d.Param);
                    if (d.ParamDefault.HasValue) { sb.Append(','); WriteKey(sb, "paramDefault"); sb.Append(JsNum(d.ParamDefault.Value)); }
                    if (d.Multiply.HasValue) { sb.Append(','); WriteKey(sb, "multiply"); sb.Append(JsNum(d.Multiply.Value)); }
                    if (d.Power.HasValue) { sb.Append(','); WriteKey(sb, "power"); sb.Append(JsNum(d.Power.Value)); }
                    if (d.DefaultValue.HasValue) { sb.Append(','); WriteKey(sb, "default"); sb.Append(JsNum(d.DefaultValue.Value)); }
                    sb.Append('}');
                    break;
                case DimKind.ScreenDivide:
                    sb.Append('{'); WriteKey(sb, "screenDivide"); WriteJsonString(sb, d.ScreenDivide);
                    if (d.DefaultValue.HasValue) { sb.Append(','); WriteKey(sb, "default"); sb.Append(JsNum(d.DefaultValue.Value)); }
                    sb.Append('}');
                    break;
                case DimKind.Scale:
                    sb.Append('{'); WriteKey(sb, "scale"); sb.Append(JsNum(d.Scale));
                    if (d.ClampMin.HasValue || d.ClampMax.HasValue)
                    {
                        sb.Append(','); WriteKey(sb, "clamp"); sb.Append('{');
                        bool wrote = false;
                        if (d.ClampMin.HasValue) { WriteKey(sb, "min"); sb.Append(JsNum(d.ClampMin.Value)); wrote = true; }
                        if (d.ClampMax.HasValue) { if (wrote) sb.Append(','); WriteKey(sb, "max"); sb.Append(JsNum(d.ClampMax.Value)); }
                        sb.Append('}');
                    }
                    sb.Append('}');
                    break;
            }
        }

        private static void WriteUniform(StringBuilder sb, UniformValue u)
        {
            switch (u.Kind)
            {
                case UniformValueKind.Null: sb.Append("null"); break;
                case UniformValueKind.Number: sb.Append(JsNum(u.Number)); break;
                case UniformValueKind.Bool: sb.Append(u.Bool ? "true" : "false"); break;
                case UniformValueKind.String: WriteJsonString(sb, u.String); break;
                case UniformValueKind.NumberArray:
                    sb.Append('[');
                    for (int i = 0; i < u.NumberArray.Count; i++) { if (i > 0) sb.Append(','); sb.Append(JsNum(u.NumberArray[i])); }
                    sb.Append(']');
                    break;
                default: sb.Append("null"); break; // Object/automation: out of first-cut scope
            }
        }

        private static void WriteStringMap(StringBuilder sb, OrderedMap<string, string> map)
        {
            sb.Append('{');
            bool f = true;
            foreach (var kv in map)
            {
                if (!f) sb.Append(','); f = false;
                WriteKey(sb, kv.Key); WriteJsonString(sb, kv.Value);
            }
            sb.Append('}');
        }

        private static void WriteString(StringBuilder sb, string key, string value)
        {
            WriteKey(sb, key); WriteJsonString(sb, value);
        }
        private static void WriteKey(StringBuilder sb, string key)
        {
            WriteJsonString(sb, key); sb.Append(':');
        }
        private static void WriteJsonString(StringBuilder sb, string s)
        {
            if (s == null) { sb.Append("null"); return; }
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }

        // JS JSON.stringify number formatting: integers without ".0", others round-trip.
        private static string JsNum(double v)
        {
            if (v == Math.Floor(v) && !double.IsInfinity(v) && Math.Abs(v) < 1e15)
                return ((long)v).ToString(CultureInfo.InvariantCulture);
            return v.ToString("R", CultureInfo.InvariantCulture);
        }
    }
}
