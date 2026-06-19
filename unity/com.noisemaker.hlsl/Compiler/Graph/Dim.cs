// Dim.cs — a texture dimension value (width / height / depth).
//
// Per GRAPH-JSON-SCHEMA.md and reference/03 §2.4 / reference/04 §9, a dimension is
// one of:
//   - a number                          -> DimKind.Number
//   - "screen" / "auto"                  -> DimKind.Screen  (both fold to screen size)
//   - a percent string "6.25%"           -> DimKind.Percent (Percent holds 6.25)
//   - { param, paramDefault?, multiply?, power?, default? }   -> DimKind.Param
//   - { screenDivide, default? }         -> DimKind.ScreenDivide
//   - { scale, clamp?:{min?,max?} }      -> DimKind.Scale
//
// This is a PURE data carrier — it does NOT resolve to a pixel count. The runtime
// executor (TexturePool / SurfaceManager) owns resolveDimension with the exact
// rounding rules (floor for param/percent/scale, round for screenDivide,
// max(1,...)). All numeric fields are double to match JS precision.
//
// Optional doubles use double? (null == JS undefined/absent). 0 is a valid value
// and is NOT treated as missing, matching the reference's `??` / `!== undefined`
// distinction (reference/03 §9 hazard 5).

namespace Noisemaker.Hlsl.Compiler.Graph
{
    public enum DimKind { Number, Screen, Percent, Param, ScreenDivide, Scale }

    public sealed class Dim
    {
        public DimKind Kind { get; private set; }

        // Number
        public double Number { get; private set; }

        // Percent: the parsed numerator, e.g. "6.25%" -> 6.25
        public double Percent { get; private set; }

        // Param variant: { param, paramDefault?, multiply?, power?, default? }
        public string Param { get; private set; }
        public double? ParamDefault { get; private set; }
        public double? Multiply { get; private set; }
        public double? Power { get; private set; }

        // ScreenDivide variant: { screenDivide, default? }
        public string ScreenDivide { get; private set; }

        // Scale variant: { scale, clamp?:{min?,max?} }
        public double Scale { get; private set; }
        public double? ClampMin { get; private set; }
        public double? ClampMax { get; private set; }

        // Shared `default` field used by Param, ScreenDivide. Kept distinct from
        // the C# `default` keyword via the name DefaultValue.
        public double? DefaultValue { get; private set; }

        private Dim() { }

        public static Dim FromNumber(double n) =>
            new Dim { Kind = DimKind.Number, Number = n };

        public static Dim FromScreen() =>
            new Dim { Kind = DimKind.Screen };

        public static Dim FromPercent(double pct) =>
            new Dim { Kind = DimKind.Percent, Percent = pct };

        public static Dim FromParam(string param, double? paramDefault, double? multiply,
                                    double? power, double? defaultValue) =>
            new Dim
            {
                Kind = DimKind.Param,
                Param = param,
                ParamDefault = paramDefault,
                Multiply = multiply,
                Power = power,
                DefaultValue = defaultValue
            };

        public static Dim FromScreenDivide(string screenDivide, double? defaultValue) =>
            new Dim
            {
                Kind = DimKind.ScreenDivide,
                ScreenDivide = screenDivide,
                DefaultValue = defaultValue
            };

        public static Dim FromScale(double scale, double? clampMin, double? clampMax) =>
            new Dim
            {
                Kind = DimKind.Scale,
                Scale = scale,
                ClampMin = clampMin,
                ClampMax = clampMax
            };
    }
}
