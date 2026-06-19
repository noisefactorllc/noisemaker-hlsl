// DslSyntaxError.cs — the lexer/parser throw type.
//
// reference/01 §1.4 / §2: the JS front-end throws `SyntaxError` whose message ends
// with " at line L col C" (the error-formatter regex /at line (\d+) col(?:umn)? (\d+)/
// parses it back out, reference/01 §9). This exception mirrors that: the Message is
// the full "<core> at line L col C" string so a C# error formatter can apply the
// same regex and caret math. Lexer/parser errors are FATAL (thrown), unlike the
// validator's collected diagnostics (reference/02 §7 H11).

using System;

namespace Noisemaker.Hlsl.Compiler
{
    public sealed class DslSyntaxError : Exception
    {
        public DslSyntaxError(string message) : base(message) { }

        // Convenience matching the JS `throw new SyntaxError(`${msg} at line L col C`)`.
        public static DslSyntaxError At(string message, int line, int col)
        {
            return new DslSyntaxError(message + " at line " + line + " col " + col);
        }
    }
}
