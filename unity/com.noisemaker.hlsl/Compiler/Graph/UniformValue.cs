// UniformValue.cs — a literal uniform value flowing through the graph.
//
// reference/03 §2.1 / §9 hazard 11: "all uniform values flow as JS doubles until
// the backend casts to f32 at upload." A uniform literal in the normalized graph
// is one of: number (double), bool, string (rare; member-enum names are resolved
// to ints upstream), an array of numbers (vec2/3/4, palettes), or null.
//
// Automation configs (Oscillator/Midi/Audio) appear in graph.uniforms as objects
// in the live runtime; this is a graph-DATA model, so an object value is preserved
// as its raw JsonValue (Object kind) for the runtime's UniformBinder to interpret
// (reference/04 §10.4). Keeping the raw JsonValue avoids lossy down-casting.

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler.Graph
{
    public enum UniformValueKind { Null, Number, Bool, String, NumberArray, Object }

    public sealed class UniformValue
    {
        public UniformValueKind Kind { get; private set; }

        public double Number { get; private set; }
        public bool Bool { get; private set; }
        public string String { get; private set; }
        public IReadOnlyList<double> NumberArray { get; private set; }

        // For automation configs / structured values, the raw JSON is retained.
        public JsonValue Object { get; private set; }

        private UniformValue() { }

        public static readonly UniformValue Null =
            new UniformValue { Kind = UniformValueKind.Null };

        public static UniformValue Of(double n) =>
            new UniformValue { Kind = UniformValueKind.Number, Number = n };
        public static UniformValue Of(bool b) =>
            new UniformValue { Kind = UniformValueKind.Bool, Bool = b };
        public static UniformValue Of(string s) =>
            new UniformValue { Kind = UniformValueKind.String, String = s };
        public static UniformValue Of(IReadOnlyList<double> arr) =>
            new UniformValue { Kind = UniformValueKind.NumberArray, NumberArray = arr };
        public static UniformValue OfObject(JsonValue obj) =>
            new UniformValue { Kind = UniformValueKind.Object, Object = obj };

        public int AsInt { get { return (int)Number; } }
        public float AsFloat { get { return (float)Number; } }
    }
}
