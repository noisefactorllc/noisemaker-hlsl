// EffectRegistry.cs — loads effect definitions and exposes the op/spec/starter/namespace
// tables the Validator and Expander need (reference/02 §10, reference/03 §3,
// reference/04 §2 registry).
//
// The runtime ships effect definitions as JSON under
//   unity/com.noisemaker.hlsl/Effects/<ns>/<effect>.json
// converted from shaders/effects/<ns>/<effect>/definition.js (PORTING-GUIDE §3 item 3:
// "name/namespace/func/globals/passes/textures"). This class:
//   1. Holds the EffectDefinition (the structured fields the Expander reads, reference/03 §3).
//   2. Derives the op `spec.args` list the Validator consumes (reference/02 §5.5),
//      mirroring canvas.js registerEffectWithRuntime EXACTLY:
//        - args is an ORDERED list over Object.entries(globals) (insertion order).
//        - type 'vec4' is rewritten to 'color' (the only type rewrite).
//        - enumPath = spec.enum || spec.enumPath; when spec.choices and no enumPath,
//          enumPath := "<ns>.<func>.<key>" and the choices are registered as enums.
//        - {name,type,default,enum,enumPath,min,max,uniform,choices} carried verbatim.
//   3. Tracks valid namespaces (for `search` validation) and starter ops (manifest flag).
//   4. Registers param aliases / effect aliases / choice enums.
//
// getEffect(name) returns the definition for the FULLY-QUALIFIED op name ("<ns>.<func>")
// AND the bare func, matching the reference registry's multi-key registration
// (canvas.js registerEffectWithRuntime registers func, ns.func, ns/name, ns.name).
//
// Pure C#, no UnityEngine. Uses the Graph-namespace JSON reader for parsing.

using System;
using System.Collections.Generic;
using System.IO;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl.Compiler
{
    // The op param spec the Validator iterates (spec.args[i]); reference/02 §5.5 ParamDef.
    public sealed class ParamDef
    {
        public string Name { get; set; }     // DSL parameter name (THE key in compiled args)
        public string Type { get; set; }     // float|int|surface|color|vec3|vec4|boolean|member|volume|geometry|string|...
        public JsonValue Default { get; set; } // default value (may be number/string/array/bool/null)
        public bool HasMin { get; set; }
        public double Min { get; set; }
        public bool HasMax { get; set; }
        public double Max { get; set; }
        public string Uniform { get; set; }   // GPU uniform name (NOT the args key — reference/02 H9)
        public string Enum { get; set; }       // enum prefix
        public string EnumPath { get; set; }   // enum prefix (takes precedence form)
        public OrderedMap<string, double> Choices { get; set; } // inline named choices, null if none
        public string DefaultFrom { get; set; } // fallback param (by DSL name)
    }

    public sealed class OpSpec
    {
        public string Name { get; set; }                 // bare func
        public string OpName { get; set; }                // "<ns>.<func>"
        public List<ParamDef> Args { get; set; } = new List<ParamDef>();
        public EffectDefinition Effect { get; set; }      // back-reference for the Expander
    }

    // The structured effect fields the Expander consumes (reference/03 §3). Raw JSON is
    // kept so passes/textures/globals can be read with their exact insertion order.
    public sealed class EffectDefinition
    {
        public string Name { get; set; }
        public string Namespace { get; set; }
        public string Func { get; set; }
        public bool Starter { get; set; }
        public JsonValue Globals { get; set; }       // { paramName: GlobalDef }  (ordered object)
        public JsonValue Passes { get; set; }         // [ PassDef ]
        public JsonValue Textures { get; set; }        // { texName: TextureSpec }
        public JsonValue Textures3d { get; set; }
        public JsonValue Shaders { get; set; }         // { progName: ShaderSource } (optional)
        public JsonValue UniformLayout { get; set; }
        public JsonValue UniformLayouts { get; set; }
        public string ExternalTexture { get; set; }
        public string OutputTex { get; set; }
        public string OutputTex3d { get; set; }
        public string OutputGeo { get; set; }
        public string OutputXyz { get; set; }
        public string OutputVel { get; set; }
        public string OutputRgba { get; set; }
        public JsonValue Raw { get; set; }
    }

    public sealed class EffectRegistry
    {
        // op name -> spec. Keyed by both "<ns>.<func>" and bare "<func>" (reference parity).
        private readonly Dictionary<string, OpSpec> _ops = new Dictionary<string, OpSpec>();
        private readonly Dictionary<string, EffectDefinition> _effects =
            new Dictionary<string, EffectDefinition>();

        // Starter op names (bare AND namespaced), reference/02 §9 STARTER_OPS.
        private readonly HashSet<string> _starterOps = new HashSet<string>();
        // Valid namespace ids for `search` validation (reference/01 §3.2).
        private readonly HashSet<string> _namespaces = new HashSet<string>();

        // Deprecated effect aliases (reference/01 §8.4): "<ns>.<func>" -> replacement name.
        private readonly Dictionary<string, string> _effectAliases = new Dictionary<string, string>();
        // Param aliases (reference/01 §8.5): opName -> { oldParam: newParam } (ordered).
        private readonly Dictionary<string, OrderedMap<string, string>> _paramAliases =
            new Dictionary<string, OrderedMap<string, string>>();

        public IReadOnlyCollection<string> Namespaces { get { return _namespaces; } }

        // --- public API -----------------------------------------------------

        public bool IsValidNamespace(string ns) { return _namespaces.Contains(ns); }

        public OpSpec GetOp(string opName)
        {
            OpSpec s;
            return _ops.TryGetValue(opName, out s) ? s : null;
        }

        public EffectDefinition GetEffect(string name)
        {
            EffectDefinition d;
            return _effects.TryGetValue(name, out d) ? d : null;
        }

        // reference/02 §9 isStarterOp.
        public bool IsStarterOp(string name)
        {
            if (name == null) return false;
            if (name == "particles" || name == "render.particles") return false; // hard override
            if (_starterOps.Contains(name)) return true;
            string[] parts = name.Split('.');
            if (parts.Length > 1)
            {
                string canonical = parts[parts.Length - 1];
                if (_starterOps.Contains(canonical))
                {
                    foreach (string op in _starterOps)
                        if (op.EndsWith("." + canonical, StringComparison.Ordinal)) return false;
                    return true;
                }
            }
            return false;
        }

        // reference/01 §8.4 checkEffectAlias.
        public string CheckEffectAlias(string opName)
        {
            string newName;
            if (!_effectAliases.TryGetValue(opName, out newName)) return null;
            string oldName = opName.Contains(".")
                ? opName.Substring(opName.LastIndexOf('.') + 1) : opName;
            return "effect '" + oldName + "' is deprecated, use '" + newName +
                   "' instead. Aliases will be removed on 2026-09-01.";
        }

        // reference/01 §8.5 resolveParamAliases — mutates kwargs in place; returns warnings.
        public List<string> ResolveParamAliases(string opName, OrderedKwargs kwargs)
        {
            var warnings = new List<string>();
            OrderedMap<string, string> aliases;
            if (!_paramAliases.TryGetValue(opName, out aliases)) return warnings;
            foreach (string oldName in aliases.Keys)
            {
                if (!kwargs.Has(oldName)) continue;
                string newName = aliases[oldName];
                if (!kwargs.Has(newName))
                    kwargs.Set(newName, kwargs.Get(oldName));
                kwargs.Remove(oldName);
                warnings.Add("param '" + oldName + "' is deprecated, use '" + newName +
                             "' instead. Aliases will be removed on 2026-09-01.");
            }
            return warnings;
        }

        // --- loading --------------------------------------------------------

        // Load every Effects/<ns>/<effect>.json under a root directory and register it.
        // TODO(verify): no Unity here — exercise once the JSON definitions are shipped.
        public static EffectRegistry LoadFromDirectory(string effectsRoot)
        {
            var reg = new EffectRegistry();
            if (!Directory.Exists(effectsRoot)) return reg;
            string[] files = Directory.GetFiles(effectsRoot, "*.json", SearchOption.AllDirectories);
            Array.Sort(files, StringComparer.Ordinal); // deterministic registration order
            foreach (string file in files)
            {
                string text = File.ReadAllText(file);
                JsonValue json = JsonValue.Parse(text);
                reg.Register(json);
            }
            return reg;
        }

        // Register a single effect-definition JSON object.
        public void Register(JsonValue def)
        {
            if (def == null || def.Kind != JsonKind.Object) return;

            var e = new EffectDefinition
            {
                Name = Str(def, "name"),
                Namespace = Str(def, "namespace"),
                Func = Str(def, "func"),
                Starter = Bool(def, "starter"),
                Globals = def.Get("globals"),
                Passes = def.Get("passes"),
                Textures = def.Get("textures"),
                Textures3d = def.Get("textures3d"),
                Shaders = def.Get("shaders"),
                UniformLayout = def.Get("uniformLayout"),
                UniformLayouts = def.Get("uniformLayouts"),
                ExternalTexture = Str(def, "externalTexture"),
                OutputTex = Str(def, "outputTex"),
                OutputTex3d = Str(def, "outputTex3d"),
                OutputGeo = Str(def, "outputGeo"),
                OutputXyz = Str(def, "outputXyz"),
                OutputVel = Str(def, "outputVel"),
                OutputRgba = Str(def, "outputRgba"),
                Raw = def
            };

            string ns = e.Namespace;
            string func = e.Func;
            if (string.IsNullOrEmpty(func)) return;
            if (!string.IsNullOrEmpty(ns)) _namespaces.Add(ns);

            // Multi-key effect registration (canvas.js registerEffectWithRuntime).
            _effects[func] = e;
            if (!string.IsNullOrEmpty(ns))
            {
                _effects[ns + "." + func] = e;
                _effects[ns + "." + e.Name] = e;
            }

            // Build the op spec exactly like registerEffectWithRuntime.
            var spec = new OpSpec { Name = func, OpName = ns + "." + func, Effect = e };
            if (e.Globals != null && e.Globals.Kind == JsonKind.Object)
            {
                foreach (var kv in e.Globals.AsObject)
                {
                    string key = kv.Key;
                    JsonValue g = kv.Value;
                    string type = Str(g, "type");
                    // enumPath = spec.enum || spec.enumPath
                    string enumPath = Str(g, "enum");
                    if (enumPath == null) enumPath = Str(g, "enumPath");

                    OrderedMap<string, double> choices = ParseChoices(g.Get("choices"));
                    if (choices != null && choices.Count > 0 && enumPath == null && ns != null)
                    {
                        // choices with no explicit enum: synthesize an enum path and
                        // register the choices as enums (canvas.js parity).
                        enumPath = ns + "." + func + "." + key;
                        foreach (var c in choices)
                            Enums.RegisterChoice(new[] { ns, func, key, c.Key }, c.Value);
                    }

                    var pd = new ParamDef
                    {
                        Name = key,
                        // vec4 -> color is the ONLY type rewrite.
                        Type = (type == "vec4") ? "color" : type,
                        Default = g.Get("default"),
                        Uniform = Str(g, "uniform"),
                        Enum = enumPath,
                        EnumPath = enumPath,
                        Choices = choices,
                        DefaultFrom = Str(g, "defaultFrom")
                    };
                    double? mn = Num(g, "min");
                    double? mx = Num(g, "max");
                    if (mn.HasValue) { pd.HasMin = true; pd.Min = mn.Value; }
                    if (mx.HasValue) { pd.HasMax = true; pd.Max = mx.Value; }
                    spec.Args.Add(pd);
                }
            }

            if (ns != null)
            {
                _ops[ns + "." + func] = spec;
                if (!_ops.ContainsKey(func)) _ops[func] = spec; // bare resolution fallback
            }
            else
            {
                _ops[func] = spec;
            }

            // Starter flag (manifest-driven, reference/02 §9): register bare + namespaced.
            if (e.Starter)
            {
                _starterOps.Add(func);
                if (ns != null) _starterOps.Add(ns + "." + func);
            }

            // paramAliases: { oldParam: newParam }
            JsonValue pa = def.Get("paramAliases");
            if (pa != null && pa.Kind == JsonKind.Object && ns != null)
            {
                var map = new OrderedMap<string, string>();
                foreach (var kv in pa.AsObject)
                    if (kv.Value.Kind == JsonKind.String) map.Add(kv.Key, kv.Value.AsString);
                _paramAliases[ns + "." + func] = map;
            }

            // deprecatedBy + hidden -> effect alias (reference/01 §8.4).
            string deprecatedBy = Str(def, "deprecatedBy");
            if (Bool(def, "hidden") && deprecatedBy != null && ns != null)
                _effectAliases[ns + "." + func] = deprecatedBy;
        }

        // --- helpers --------------------------------------------------------

        private static OrderedMap<string, double> ParseChoices(JsonValue choices)
        {
            if (choices == null || choices.Kind != JsonKind.Object) return null;
            var map = new OrderedMap<string, double>();
            foreach (var kv in choices.AsObject)
            {
                // reference skips keys ending ':' (UI separators). Numeric values only.
                if (kv.Key.EndsWith(":", StringComparison.Ordinal)) continue;
                if (kv.Value.Kind == JsonKind.Number) map.Add(kv.Key, kv.Value.AsNumber);
            }
            return map;
        }

        private static string Str(JsonValue obj, string key)
        {
            JsonValue v = obj.Get(key);
            if (v == null || v.Kind != JsonKind.String) return null;
            return v.AsString;
        }
        private static bool Bool(JsonValue obj, string key)
        {
            JsonValue v = obj.Get(key);
            return v != null && v.Kind == JsonKind.Bool && v.AsBool;
        }
        private static double? Num(JsonValue obj, string key)
        {
            JsonValue v = obj.Get(key);
            if (v == null || v.Kind != JsonKind.Number) return null;
            return v.AsNumber;
        }
    }
}
