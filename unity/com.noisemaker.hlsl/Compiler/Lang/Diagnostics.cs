// Diagnostics.cs — diagnostic codes + the collected-diagnostic record (reference/02 §7).
//
// The validator COLLECTS diagnostics (it does not throw, except missing-search,
// reference/02 §1.2 / H11). Codes + severities are the contract:
//   S001 error  Unknown identifier
//   S002 warning Argument out of range (clamp)
//   S003 error  Variable used before assignment
//   S004 error  Cannot assign null or undefined
//   S005 error  Illegal chain structure
//   S006 error  Starter chain missing write() call
//   S007 warning Deprecated parameter alias
//   S008 warning Deprecated effect
//
// Pure C#, no UnityEngine.

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler
{
    public enum DiagnosticSeverity { Error, Warning }

    public sealed class Diagnostic
    {
        public string Code { get; set; }
        public string Message { get; set; }
        public DiagnosticSeverity Severity { get; set; }
        public int? Line { get; set; }       // from node.loc when available
        public int? Column { get; set; }
        public string Identifier { get; set; } // extractIdentifierName result, when present
    }

    public static class DiagnosticTable
    {
        // code -> (default message, severity). Reference/02 §7.
        private static readonly Dictionary<string, KeyValuePair<string, DiagnosticSeverity>> _table =
            new Dictionary<string, KeyValuePair<string, DiagnosticSeverity>>
            {
                { "S001", Pair("Unknown identifier", DiagnosticSeverity.Error) },
                { "S002", Pair("Argument out of range", DiagnosticSeverity.Warning) },
                { "S003", Pair("Variable used before assignment", DiagnosticSeverity.Error) },
                { "S004", Pair("Cannot assign null or undefined", DiagnosticSeverity.Error) },
                { "S005", Pair("Illegal chain structure", DiagnosticSeverity.Error) },
                { "S006", Pair("Starter chain missing write() call", DiagnosticSeverity.Error) },
                { "S007", Pair("Deprecated parameter alias", DiagnosticSeverity.Warning) },
                { "S008", Pair("Deprecated effect", DiagnosticSeverity.Warning) },
            };

        private static KeyValuePair<string, DiagnosticSeverity> Pair(string m, DiagnosticSeverity s)
        {
            return new KeyValuePair<string, DiagnosticSeverity>(m, s);
        }

        public static string DefaultMessage(string code) { return _table[code].Key; }
        public static DiagnosticSeverity Severity(string code) { return _table[code].Value; }
    }
}
