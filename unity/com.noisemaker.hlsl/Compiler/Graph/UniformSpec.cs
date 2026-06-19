// UniformSpec.cs — consumer range for %-automation scaling.
//
// reference/03 §2.1 / reference/04 §10.4: pass.uniformSpecs maps uniformName ->
// { min, max }. Used to scale a normalized 0..1 oscillator/midi/audio percent into
// the uniform's real range: value = min + pct*(max-min). Doubles to match JS.

namespace Noisemaker.Hlsl.Compiler.Graph
{
    public sealed class UniformSpec
    {
        public double Min { get; set; }
        public double Max { get; set; }
    }
}
