// EnumPaths.cs — member-path utilities, a 1:1 port of shaders/src/lang/enumPaths.js
// (reference/01 §8.3, used by the validator's member/numeric-enum resolution).
//
//   NormalizeMemberPath : array -> filtered non-empty string segments; string -> split
//                         on '.', trim, drop empties; else null.
//   PathStartsWith      : empty prefix -> true; length guard; element compare.
//   ApplyEnumPrefix     : qualify a short member with its enum name (tries proper
//                         suffixes of prefix before prepending the whole prefix).
//
// Pure C#, no UnityEngine.

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler
{
    public static class EnumPaths
    {
        // Overload for an already-split path (array form in JS).
        public static List<string> NormalizeMemberPath(IReadOnlyList<string> value)
        {
            if (value == null) return null;
            var parts = new List<string>();
            foreach (string seg in value)
                if (!string.IsNullOrEmpty(seg)) parts.Add(seg);
            return parts.Count > 0 ? parts : null;
        }

        // Overload for the string / null form (def.enum / def.enumPath / def.default).
        public static List<string> NormalizeMemberPath(string value)
        {
            if (string.IsNullOrEmpty(value)) return null;
            string[] raw = value.Split('.');
            var parts = new List<string>();
            foreach (string seg in raw)
            {
                string t = seg.Trim();
                if (t.Length > 0) parts.Add(t);
            }
            return parts.Count > 0 ? parts : null;
        }

        public static bool PathStartsWith(IReadOnlyList<string> path, IReadOnlyList<string> prefix)
        {
            if (prefix == null || prefix.Count == 0) return true;
            if (path == null || path.Count < prefix.Count) return false;
            for (int i = 0; i < prefix.Count; i++)
                if (path[i] != prefix[i]) return false;
            return true;
        }

        public static List<string> ApplyEnumPrefix(List<string> path, List<string> prefix)
        {
            if (path == null || path.Count == 0) return path;
            if (prefix == null || prefix.Count == 0) return new List<string>(path);
            if (PathStartsWith(path, prefix)) return new List<string>(path);
            for (int i = 1; i < prefix.Count; i++)
            {
                List<string> suffix = prefix.GetRange(i, prefix.Count - i);
                if (PathStartsWith(path, suffix))
                {
                    var result = prefix.GetRange(0, i);
                    result.AddRange(path);
                    return result;
                }
            }
            var concat = new List<string>(prefix);
            concat.AddRange(path);
            return concat;
        }
    }
}
