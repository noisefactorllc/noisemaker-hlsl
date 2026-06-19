// Oscillators.cs — deterministic value-oscillator evaluation (reference/04 §11).
//
// Ports shaders/src/runtime/pipeline.js evaluateOscillator / oscNoise / noise2D /
// hash21 BIT-FOR-BIT: double throughout, JS float `% 1` remainder with the explicit
// negative sign-fix (`if (x < 0) x += 1`), magic constants 234.34 / 435.345 / 34.23,
// noise-circle radius 2, TAU = 2π. The config is a resolved Oscillator JsonValue
// (reference/02 §6.11): { oscType, min, max, speed, offset, seed }. The result is the
// raw 0..1-domain oscillator value mapped into [min,max]; the UniformBinder then scales
// it by the consumer paramSpec range (reference/04 §10.4 resolveUniformValue).
//
// PARITY HAZARD (reference/04 §11): C# `%` on double matches JS for positive operands;
// the negative sign-fix is mirrored exactly. Math.Cos/Sin use platform double trig —
// sub-ULP V8/.NET drift is possible but bounded.
//
// Pure C#, no UnityEngine.

using System;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl
{
    public static class Oscillators
    {
        private const double TAU = Math.PI * 2.0;

        // evaluateOscillator(osc, normalizedTime) — reference/04 §11.
        // cfg must be a resolved Oscillator config object.
        public static double Evaluate(JsonValue cfg, double normalizedTime)
        {
            double oscType = NumField(cfg, "oscType", 0);
            double min     = NumField(cfg, "min", 0);
            double max     = NumField(cfg, "max", 1);
            double speed   = NumField(cfg, "speed", 1);
            double offset  = NumField(cfg, "offset", 0);
            double seed    = NumField(cfg, "seed", 1);

            double t = normalizedTime * speed + offset;

            double value;
            switch ((int)oscType)
            {
                case 0: value = OscSine(t); break;
                case 1: value = OscTri(t); break;
                case 2: value = OscSaw(t); break;
                case 3: value = OscSawInv(t); break;
                case 4: value = OscSquare(t); break;
                case 5: value = OscNoise(t, seed); break;
                default: value = 0; break;
            }

            return min + value * (max - min);
        }

        // 0 sine: (1 - cos(t*TAU)) * 0.5
        private static double OscSine(double t) => (1.0 - Math.Cos(t * TAU)) * 0.5;

        // 1 tri: tf = t-floor(t); 1 - |tf*2 - 1|
        private static double OscTri(double t)
        {
            double tf = t - Math.Floor(t);
            return 1.0 - Math.Abs(tf * 2.0 - 1.0);
        }

        // 2 saw: t - floor(t)
        private static double OscSaw(double t) => t - Math.Floor(t);

        // 3 sawInv: 1 - (t - floor(t))
        private static double OscSawInv(double t) => 1.0 - (t - Math.Floor(t));

        // 4 square: (t-floor(t)) >= 0.5 ? 1 : 0
        private static double OscSquare(double t) => (t - Math.Floor(t)) >= 0.5 ? 1.0 : 0.0;

        // hash21(px,py,s): x=(px*234.34+s)%1; y=(py*435.345+s)%1; sign-fix; p=x+y+(x+y)*34.23; (x*y*p)%1
        private static double Hash21(double px, double py, double s)
        {
            double x = (px * 234.34 + s) % 1.0;
            double y = (py * 435.345 + s) % 1.0;
            if (x < 0) x += 1.0;
            if (y < 0) y += 1.0;
            double p = x + y + (x + y) * 34.23;
            return (x * y * p) % 1.0;
        }

        // noise2D(px,py,s): integer floors; smoothstep fract; bilinear of hash21 corners.
        private static double Noise2D(double px, double py, double s)
        {
            double ix = Math.Floor(px);
            double iy = Math.Floor(py);
            double fx = px - ix;
            double fy = py - iy;
            fx = fx * fx * (3.0 - 2.0 * fx);
            fy = fy * fy * (3.0 - 2.0 * fy);

            double a = Hash21(ix, iy, s);
            double b = Hash21(ix + 1.0, iy, s);
            double c = Hash21(ix, iy + 1.0, s);
            double d = Hash21(ix + 1.0, iy + 1.0, s);

            return a * (1.0 - fx) * (1.0 - fy) + b * fx * (1.0 - fy)
                 + c * (1.0 - fx) * fy + d * fx * fy;
        }

        // oscNoise(t,seed): sample value noise on a circle for a seamless temporal loop.
        private static double OscNoise(double t, double seed)
        {
            double temporal = t % 1.0;
            double angle = temporal * TAU;
            const double radius = 2.0;
            double loopX = Math.Cos(angle) * radius;
            double loopY = Math.Sin(angle) * radius;
            double n1 = Noise2D(loopX + seed, loopY + seed, seed);
            double n2 = Noise2D(loopX + seed * 2.0, loopY + seed * 2.0, seed);
            return (n1 + n2) / 2.0;
        }

        private static double NumField(JsonValue obj, string key, double fallback)
        {
            if (obj == null || obj.Kind != JsonKind.Object) return fallback;
            JsonValue v = obj.Get(key);
            return (v != null && v.Kind == JsonKind.Number) ? v.AsNumber : fallback;
        }
    }
}
