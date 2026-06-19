// Program.cs — a raw reference program spec carried in graph.programs.
//
// Per GRAPH-JSON-SCHEMA.md: "programs: optional, raw reference program specs
// (glsl/wgsl/uniformLayout/defines). The HLSL loader does NOT need shader source
// from here — it resolves a Unity Shader by (namespace, func) and pass name. Kept
// for traceability / golden diff."  (reference/03 §2.3)
//
// Because the HLSL runtime never compiles this source, the model keeps the program
// entry maximally faithful for golden-diffing rather than strongly typing every
// authored shader field: the full original JSON object is preserved in Raw, with
// the two fields the loader/diff cares about (UniformLayout, Defines) lifted out
// as typed members.
//
//   uniformLayout : { [uniformName]: { slot:number, components:string } }
//                   vec4-packing layout consumed by GLSL/WGSL backends; the HLSL
//                   port binds individual named uniforms instead (PORTING-GUIDE),
//                   so this is retained only for parity diffing.
//   defines       : { [MACRO_NAME]: int }  compile-time consts (e.g. NOISE_TYPE).

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler.Graph
{
    public sealed class UniformSlot
    {
        public int Slot { get; set; }          // vec4 register index
        public string Components { get; set; }  // "x"|"y"|"z"|"w"|"xy"|"xyz"|"xyzw"|...
    }

    public sealed class Program
    {
        // Full original program JSON object, preserved verbatim (insertion-ordered)
        // for golden diff and traceability. Includes any authored shader fields
        // (fragment/glsl/source/wgsl/vertex/entryPoint/...). May be null if a
        // producer emits only the lifted fields.
        public JsonValue Raw { get; set; }

        // Lifted: uniformLayout (may be empty). Insertion order preserved.
        public OrderedMap<string, UniformSlot> UniformLayout { get; set; }
            = new OrderedMap<string, UniformSlot>();

        // Lifted: compile-time defines MACRO_NAME -> int value. Insertion order
        // preserved (the suffix/cache key depend on sorted order at emit time, but
        // here we just store the map as authored).
        public OrderedMap<string, int> Defines { get; set; }
            = new OrderedMap<string, int>();
    }
}
