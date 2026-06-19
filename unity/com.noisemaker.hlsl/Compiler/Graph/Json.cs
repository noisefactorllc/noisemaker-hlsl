// Json.cs — a small, robust, dependency-free JSON reader (tokenizer + recursive
// descent). Pure C#: NO UnityEngine, NO Newtonsoft. Produces JsonValue trees that
// preserve object key insertion order (objects are OrderedMap<string,JsonValue>),
// which the render-graph contract depends on for parity (reference/04 §14.4).
//
// All JSON numbers are parsed as `double` (the reference treats every uniform /
// dimension value as a JS double; see GRAPH-JSON-SCHEMA.md). Typed accessors on
// JsonValue cast as needed. Parsing uses InvariantCulture so a comma decimal
// locale cannot corrupt numbers.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace Noisemaker.Hlsl.Compiler.Graph
{
    public enum JsonKind { Null, Bool, Number, String, Array, Object }

    public sealed class JsonValue
    {
        public JsonKind Kind { get; private set; }

        private readonly bool _bool;
        private readonly double _number;
        private readonly string _string;
        private readonly List<JsonValue> _array;
        private readonly OrderedMap<string, JsonValue> _object;

        private JsonValue(JsonKind kind, bool b, double n, string s,
                          List<JsonValue> arr, OrderedMap<string, JsonValue> obj)
        {
            Kind = kind; _bool = b; _number = n; _string = s; _array = arr; _object = obj;
        }

        public static readonly JsonValue Null =
            new JsonValue(JsonKind.Null, false, 0, null, null, null);

        public static JsonValue Of(bool b) =>
            new JsonValue(JsonKind.Bool, b, 0, null, null, null);
        public static JsonValue Of(double n) =>
            new JsonValue(JsonKind.Number, false, n, null, null, null);
        public static JsonValue Of(string s) =>
            s == null ? Null : new JsonValue(JsonKind.String, false, 0, s, null, null);
        public static JsonValue Of(List<JsonValue> arr) =>
            new JsonValue(JsonKind.Array, false, 0, null, arr ?? new List<JsonValue>(), null);
        public static JsonValue Of(OrderedMap<string, JsonValue> obj) =>
            new JsonValue(JsonKind.Object, false, 0, null, null,
                          obj ?? new OrderedMap<string, JsonValue>());

        public bool IsNull { get { return Kind == JsonKind.Null; } }

        // Typed accessors. Throw on kind mismatch so loader bugs surface early.
        public bool AsBool { get { Expect(JsonKind.Bool); return _bool; } }
        public double AsNumber { get { Expect(JsonKind.Number); return _number; } }
        public string AsString { get { Expect(JsonKind.String); return _string; } }
        public List<JsonValue> AsArray { get { Expect(JsonKind.Array); return _array; } }
        public OrderedMap<string, JsonValue> AsObject { get { Expect(JsonKind.Object); return _object; } }

        public int AsInt { get { return (int)AsNumber; } }

        // Object field lookup; returns null (C# null) when key absent. The caller
        // distinguishes "absent" (null) from JSON null (JsonValue with Kind==Null),
        // mirroring the reference's `!== undefined` vs `!= null` distinctions.
        public JsonValue Get(string key)
        {
            if (Kind != JsonKind.Object) return null;
            JsonValue v;
            return _object.TryGetValue(key, out v) ? v : null;
        }

        public bool Has(string key)
        {
            return Kind == JsonKind.Object && _object.ContainsKey(key);
        }

        private void Expect(JsonKind k)
        {
            if (Kind != k)
                throw new InvalidOperationException(
                    "JsonValue is " + Kind + ", expected " + k);
        }

        public static JsonValue Parse(string text)
        {
            return new JsonParser(text).ParseDocument();
        }
    }

    // Recursive-descent parser over the raw char buffer. No streaming; graphs are
    // small. Handles standard JSON plus // and /* */ comments are NOT supported
    // (the schema's .jsonc samples are illustrative; emitted graphs are strict JSON).
    internal sealed class JsonParser
    {
        private readonly string _s;
        private int _i;

        public JsonParser(string s)
        {
            _s = s ?? throw new ArgumentNullException("s");
            _i = 0;
        }

        public JsonValue ParseDocument()
        {
            SkipWs();
            JsonValue v = ParseValue();
            SkipWs();
            if (_i != _s.Length)
                throw Err("Trailing content after JSON document");
            return v;
        }

        private JsonValue ParseValue()
        {
            SkipWs();
            if (_i >= _s.Length) throw Err("Unexpected end of input");
            char c = _s[_i];
            switch (c)
            {
                case '{': return ParseObject();
                case '[': return ParseArray();
                case '"': return JsonValue.Of(ParseString());
                case 't': case 'f': return ParseBool();
                case 'n': ParseLiteral("null"); return JsonValue.Null;
                default:
                    if (c == '-' || (c >= '0' && c <= '9')) return ParseNumber();
                    throw Err("Unexpected character '" + c + "'");
            }
        }

        private JsonValue ParseObject()
        {
            Expect('{');
            var map = new OrderedMap<string, JsonValue>();
            SkipWs();
            if (Peek() == '}') { _i++; return JsonValue.Of(map); }
            while (true)
            {
                SkipWs();
                if (Peek() != '"') throw Err("Expected object key string");
                string key = ParseString();
                SkipWs();
                Expect(':');
                JsonValue val = ParseValue();
                map.Add(key, val); // last-duplicate-wins, position preserved (JS parity)
                SkipWs();
                char c = Next();
                if (c == ',') continue;
                if (c == '}') break;
                throw Err("Expected ',' or '}' in object");
            }
            return JsonValue.Of(map);
        }

        private JsonValue ParseArray()
        {
            Expect('[');
            var list = new List<JsonValue>();
            SkipWs();
            if (Peek() == ']') { _i++; return JsonValue.Of(list); }
            while (true)
            {
                list.Add(ParseValue());
                SkipWs();
                char c = Next();
                if (c == ',') continue;
                if (c == ']') break;
                throw Err("Expected ',' or ']' in array");
            }
            return JsonValue.Of(list);
        }

        private string ParseString()
        {
            Expect('"');
            var sb = new StringBuilder();
            while (true)
            {
                if (_i >= _s.Length) throw Err("Unterminated string");
                char c = _s[_i++];
                if (c == '"') break;
                if (c == '\\')
                {
                    if (_i >= _s.Length) throw Err("Unterminated escape");
                    char e = _s[_i++];
                    switch (e)
                    {
                        case '"': sb.Append('"'); break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'u':
                            if (_i + 4 > _s.Length) throw Err("Bad \\u escape");
                            int cp = int.Parse(_s.Substring(_i, 4),
                                NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                            _i += 4;
                            sb.Append((char)cp);
                            break;
                        default: throw Err("Invalid escape '\\" + e + "'");
                    }
                }
                else
                {
                    sb.Append(c);
                }
            }
            return sb.ToString();
        }

        private JsonValue ParseNumber()
        {
            int start = _i;
            if (Peek() == '-') _i++;
            while (_i < _s.Length)
            {
                char c = _s[_i];
                if ((c >= '0' && c <= '9') || c == '.' || c == 'e' || c == 'E'
                    || c == '+' || c == '-') _i++;
                else break;
            }
            string token = _s.Substring(start, _i - start);
            double d = double.Parse(token, NumberStyles.Float, CultureInfo.InvariantCulture);
            return JsonValue.Of(d);
        }

        private JsonValue ParseBool()
        {
            if (Peek() == 't') { ParseLiteral("true"); return JsonValue.Of(true); }
            ParseLiteral("false"); return JsonValue.Of(false);
        }

        private void ParseLiteral(string lit)
        {
            if (_i + lit.Length > _s.Length || _s.Substring(_i, lit.Length) != lit)
                throw Err("Expected literal '" + lit + "'");
            _i += lit.Length;
        }

        private void SkipWs()
        {
            while (_i < _s.Length)
            {
                char c = _s[_i];
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') _i++;
                else break;
            }
        }

        private char Peek() { return _i < _s.Length ? _s[_i] : '\0'; }
        private char Next()
        {
            if (_i >= _s.Length) throw Err("Unexpected end of input");
            return _s[_i++];
        }
        private void Expect(char c)
        {
            char got = Next();
            if (got != c) throw Err("Expected '" + c + "' but got '" + got + "'");
        }

        private Exception Err(string msg)
        {
            return new FormatException("JSON parse error at index " + _i + ": " + msg);
        }
    }
}
