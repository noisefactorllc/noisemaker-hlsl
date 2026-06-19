// Plan.cs — the validated, flattened plan list (the validator -> expander contract,
// reference/02 §4.2 / §5, reference/03 §1.1).
//
// A Plan is one top-level chain: { chain: Step[], write, write3d, final, states }.
// A Step is { op, args, from, temp, builtin? } with resolved arg values. The expander
// reads step.op / step.from / step.temp / step.builtin / step.args and plan.write.
//
// ArgValue is a discriminated union mirroring the reference ArgValue (reference/03 §1.1):
//   - Number / Bool / String / NumberArray : literal uniform values
//   - Surface : { kind, name } or { kind:'temp', index } texture/surface refs
//   - Wrapped : an automation object ({type:'Oscillator'|'Midi'|'Audio', ...}) or a
//               {_varRef, value} wrapper — staged in this first cut (see DslCompiler).
//   - Skip    : the _skip sentinel (true) lives on args as ArgValue.Bool(true) under key "_skip".
//
// Pure C#, no UnityEngine.

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler
{
    public enum ArgKind { Number, Bool, String, NumberArray, Surface, Wrapped }

    // Surface descriptor kinds (reference/02 §2.3 toSurface + §5.1 builtin args +
    // §6.1 surface resolution). 'temp' carries Index instead of Name.
    public sealed class SurfaceRef
    {
        public string Kind { get; set; }   // output|source|xyz|vel|rgba|mesh|vol|geo|temp|state|pipeline|feedback
        public string Name { get; set; }   // surface name (null for temp)
        public int Index { get; set; }      // upstream step temp (only for kind=='temp')
        public bool HasIndex { get; set; }
    }

    public sealed class ArgValue
    {
        public ArgKind Kind { get; private set; }
        public double Number { get; private set; }
        public bool Bool { get; private set; }
        public string String { get; private set; }
        public IReadOnlyList<double> NumberArray { get; private set; }
        public SurfaceRef Surface { get; private set; }
        // For automation/wrapped objects preserved verbatim for the runtime binder.
        public object Wrapped { get; private set; }

        public static ArgValue Of(double n) => new ArgValue { Kind = ArgKind.Number, Number = n };
        public static ArgValue Of(bool b) => new ArgValue { Kind = ArgKind.Bool, Bool = b };
        public static ArgValue OfString(string s) => new ArgValue { Kind = ArgKind.String, String = s };
        public static ArgValue OfArray(IReadOnlyList<double> a) =>
            new ArgValue { Kind = ArgKind.NumberArray, NumberArray = a };
        public static ArgValue OfSurface(SurfaceRef s) =>
            new ArgValue { Kind = ArgKind.Surface, Surface = s };
        public static ArgValue OfWrapped(object w) =>
            new ArgValue { Kind = ArgKind.Wrapped, Wrapped = w };
    }

    // Insertion-ordered args map (JS object key order is parity-significant for the
    // expander's two-pass arg iteration, reference/03 §4.8).
    public sealed class StepArgs
    {
        private readonly List<string> _keys = new List<string>();
        private readonly Dictionary<string, ArgValue> _map = new Dictionary<string, ArgValue>();
        public int Count { get { return _keys.Count; } }
        public IReadOnlyList<string> Keys { get { return _keys; } }
        public void Set(string k, ArgValue v)
        {
            if (!_map.ContainsKey(k)) _keys.Add(k);
            _map[k] = v;
        }
        public bool Has(string k) { return _map.ContainsKey(k); }
        public bool TryGet(string k, out ArgValue v) { return _map.TryGetValue(k, out v); }
        public ArgValue Get(string k) { ArgValue v; return _map.TryGetValue(k, out v) ? v : null; }
    }

    public sealed class Step
    {
        public string Op { get; set; }       // fully-qualified op name, or "_read"/"_write"/...
        public StepArgs Args { get; set; } = new StepArgs();
        public int? From { get; set; }        // upstream temp index; null for starter root
        public int Temp { get; set; }          // this step's output temp index
        public bool Builtin { get; set; }      // true for _read/_write/_read3d/_write3d/_subchain_*
        public List<string> LeadingComments { get; set; }
    }

    // plan.write target: { kind:'output', name } (reference/02 §4.2 writeSurf).
    public sealed class WriteTarget
    {
        public string Kind { get; set; }   // "output"
        public string Name { get; set; }
    }

    public sealed class Plan
    {
        public List<Step> Chain { get; set; } = new List<Step>();
        public WriteTarget Write { get; set; }       // null when none
        // 3D write target { tex3d:{kind:'vol',name}, geo:{kind:'geo',name} } — staged.
        public SurfaceRef Write3dTex3d { get; set; }
        public SurfaceRef Write3dGeo { get; set; }
        public int? Final { get; set; }               // temp index of last produced step
    }

    public sealed class ValidateResult
    {
        public List<Plan> Plans { get; set; } = new List<Plan>();
        public List<Diagnostic> Diagnostics { get; set; } = new List<Diagnostic>();
        public string Render { get; set; }            // ast.render.name ?? null
        public List<string> SearchNamespaces { get; set; } = new List<string>();
    }
}
