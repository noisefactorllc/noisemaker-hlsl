// Pass.cs — one GPU pass in the normalized render graph.
//
// Mirrors the normalized Pass shape from GRAPH-JSON-SCHEMA.md ("## Pass
// (normalized)") and reference/03 §2.1 / §2.2. Effect passes and blit passes share
// this one class; PassType ("effect" | "blit") and the convenience fields
// (Namespace/Func/ProgName) added by the normalizer let the HLSL loader resolve a
// Unity Shader without decoding program-id strings.
//
// Ordering note (PARITY, reference/04 §1.3, §14.4): Defines, Inputs, Outputs,
// Uniforms, UniformSpecs are insertion-ordered. phys_N pooling walks
// Object.values(pass.outputs)/inputs in order, and uniform fan-out depends on it.
// Numbers are double; ints that the schema types as int (Count, DrawBuffers,
// StepIndex, define values) are exposed as int.

namespace Noisemaker.Hlsl.Compiler.Graph
{
    public enum PassType { Effect, Blit }

    // Pass run/skip gating (reference/04 §10.3 Pipeline.shouldSkipPass). A pass with
    // conditions runs only when its runIf/skipIf predicates resolve true against the
    // live uniform values. Used by pointsBillboardRender's two deposit passes (one
    // additive, one premultiplied-alpha) so only the one matching blendMode executes.
    // Each predicate compares a uniform's resolved value against a numeric `equals`.
    public sealed class PassCondition
    {
        public string Uniform { get; set; }
        // The value the uniform must equal (named EqualsValue to avoid hiding
        // object.Equals). Serialized as the JSON key "equals".
        public double EqualsValue { get; set; }
    }

    public sealed class PassConditions
    {
        // skip the pass if ANY skipIf predicate matches (uniform == equals).
        public System.Collections.Generic.List<PassCondition> SkipIf { get; set; }
        // run the pass only if ALL runIf predicates match; skip otherwise.
        public System.Collections.Generic.List<PassCondition> RunIf { get; set; }
    }

    // Repeat: int or uniform-name string ("run pass N times/frame"). reference/03
    // §2.1, reference/04 §10.5. Exactly one of IsCount / IsUniformName holds.
    public sealed class Repeat
    {
        public bool IsCount { get; private set; }
        public int Count { get; private set; }              // valid when IsCount
        public bool IsUniformName { get; private set; }
        public string UniformName { get; private set; }     // valid when IsUniformName

        private Repeat() { }

        public static Repeat FromCount(int n) =>
            new Repeat { IsCount = true, Count = n };
        public static Repeat FromUniform(string name) =>
            new Repeat { IsUniformName = true, UniformName = name };
    }

    public sealed class Pass
    {
        // --- identity / type ---
        public string Id { get; set; }
        public PassType PassType { get; set; }

        // --- shader resolution (normalizer convenience fields) ---
        public string Namespace { get; set; }   // pass.effectNamespace; may be null
        public string Func { get; set; }         // pass.effectFunc (fallback effectName)
        public string ProgName { get; set; }     // bare program basename
        public string Program { get; set; }      // full program key into graph.Programs

        // compile-time consts -> bound as int uniforms / #defines. Insertion order.
        public OrderedMap<string, int> Defines { get; set; }
            = new OrderedMap<string, int>();

        // --- pass wiring ---
        // samplerName -> texId | "none". Insertion order is liveness-significant.
        public OrderedMap<string, string> Inputs { get; set; }
            = new OrderedMap<string, string>();
        // attachment ("color","color1",...) -> texId. Insertion order is MRT layout
        // AND pooling-significant.
        public OrderedMap<string, string> Outputs { get; set; }
            = new OrderedMap<string, string>();
        // uniformName -> literal value (double/bool/string/array/automation object).
        public OrderedMap<string, UniformValue> Uniforms { get; set; }
            = new OrderedMap<string, UniformValue>();
        // uniformName -> { min, max } for %-automation scaling.
        public OrderedMap<string, UniformSpec> UniformSpecs { get; set; }
            = new OrderedMap<string, UniformSpec>();

        // --- optional execution modifiers ---
        public string DrawMode { get; set; }     // e.g. "points"; null = fullscreen
        public int? Count { get; set; }           // literal vertex/instance count (numeric count)
        // String count mode ("input" | "auto" | "screen") when count is a string in JSON
        // (reference webgl2.js §points: count may be 'input'/'auto'/'screen'). For "input"
        // the count = referenced input RT width*height; for "auto"/"screen" the output/
        // screen dims. Mutually exclusive with the numeric Count. null when count numeric/absent.
        public string CountMode { get; set; }
        public string CountUniform { get; set; }  // dynamic count from a uniform
        public int? DrawBuffers { get; set; }     // MRT attachment count
        public bool Blend { get; set; }           // additive deposit -> Blend One One
        // Explicit two-factor blend [src, dst] (reference webgl2 array form), e.g.
        // ["ONE","ONE_MINUS_SRC_ALPHA"] for premultiplied OVER, or ["one","one"] for
        // additive. null when blend is absent or the plain bool `true` (== additive
        // ONE/ONE). Blend stays truthy whenever BlendFactors is non-null. The Unity
        // backend bakes blend state in the .shader, so a premultiplied-OVER factor pair
        // routes the draw to a distinct `<progName>_alpha` shader pass (NMShaderRegistry).
        public string[] BlendFactors { get; set; }
        public Repeat Repeat { get; set; }        // run pass N times/frame; null = once
        public JsonValue Clear { get; set; }      // backend-interpreted; null when absent

        // VOLUME-WRITE viewport (reference/04 §10 Pass.viewport, synth3d/filter3d JSON).
        // When present, the pass renders into an explicit pixel region (the volume ATLAS
        // dims, e.g. 64 x 4096) instead of the full output-RT size, AND _NM_Resolution is
        // overridden to these dims so NM_FragCoord (= uv * _NM_Resolution) recovers the
        // integer atlas pixel -> voxel addressing. width/height are Dims resolved with the
        // same rules as texture dims (param->64, param^power->4096). null = full-target,
        // screen resolution (the common 2D effect case). See NMRenderBackend.ExecutePass.
        public Dim ViewportWidth { get; set; }    // null when absent
        public Dim ViewportHeight { get; set; }   // null when absent

        // --- metadata ---
        public string EffectKey { get; set; }
        public string NodeId { get; set; }
        public int? StepIndex { get; set; }       // step.temp; null on final_blit
        public bool InheritsVolumeSize { get; set; }
        // { origParam: scopedParam }; null when absent (reference/03 §6.3).
        public OrderedMap<string, string> ScopedParams { get; set; }  // null when absent

        // --- DSL LOOPS (subchain(iterations:N) bracket) ---
        // Passes emitted inside an iterated subchain bracket share a LoopGroupId and
        // carry the per-bracket LoopIterations count. The runtime runs the contiguous
        // run of passes with the same LoopGroupId N times, ping-ponging between
        // iterations (reference/04 §10.6 swapIterationBuffers). LoopGroupId == 0 means
        // "not in a loop" — preserves linear/multi-statement behavior unchanged.
        public int LoopGroupId { get; set; }       // 0 = none
        public int LoopIterations { get; set; }    // >1 only when LoopGroupId != 0

        // --- run/skip gating (reference/04 §10.3) ---
        // Per-pass runIf/skipIf predicates; null when the pass has no conditions.
        public PassConditions Conditions { get; set; }
    }
}
