// Ast.cs — the parsed DSL AST ("plans"), per reference/01 §6.
//
// The reference parser emits plain JS objects discriminated by a `type` string. This
// C# model uses a class hierarchy with the EXACT field set each node carries
// (reference/01 §6.1-§6.5). Names match the reference `type` strings via NodeKind so
// downstream stages (Validator/Expander) can dispatch identically.
//
// PARITY notes:
//  - Number.Value is a DOUBLE carrying the parse-time constant fold (reference/01 §4.4).
//  - Color.Value is a 4-double array in 0..1 units (reference/01 §5); no colorspace.
//  - String.Value is RAW (escapes NOT decoded; reference/01 §1.4 rules 15/16).
//  - The chain-statement wrapper (ChainStatement) has NO `type` in the reference; it is
//    identified by the presence of `chain` (reference/01 §6.2). Here it is its own class.
//  - Member.Path has >= 2 segments; a single segment becomes Ident (reference/01 §4.5).
//
// Pure C#, no UnityEngine.

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler
{
    public enum NodeKind
    {
        Program,
        VarAssign,
        IfStmt,
        Break,
        Continue,
        Return,
        ChainStatement, // wrapper { chain, write, write3d } — no `type` in reference
        Call,
        Write,
        Write3D,
        Subchain,
        Read,
        Read3D,
        Number,
        String,
        Boolean,
        Color,
        ArrayLiteral,
        Func,
        Ident,
        Member,
        Chain,          // {type:'Chain', chain} value wrapper (reference/01 §4.5)
        OutputRef,
        SourceRef,
        VolRef,
        GeoRef,
        XyzRef,
        VelRef,
        RgbaRef,
        MeshRef,
        Oscillator,
        Midi,
        Audio
    }

    public abstract class Node
    {
        public abstract NodeKind Kind { get; }
        // Round-trip metadata that appears on several node types (reference/01 §6).
        public List<string> LeadingComments { get; set; }
        // Source location { line, col } where the reference attaches loc (e.g. Write,
        // Subchain, ArrayLiteral, Oscillator/Midi/Audio). null otherwise.
        public int? LocLine { get; set; }
        public int? LocCol { get; set; }
    }

    // ---- Program root (reference/01 §6.1) ------------------------------------

    public sealed class NamespaceImport
    {
        public string Name { get; set; }
        public string Source { get; set; }   // always "search" here
        public bool Explicit { get; set; }    // always true here
    }

    public sealed class NamespaceMeta
    {
        public List<NamespaceImport> Imports { get; set; } = new List<NamespaceImport>();
        public NamespaceImport Default { get; set; }     // may be null
        public List<string> SearchOrder { get; set; } = new List<string>();
    }

    public sealed class ProgramNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Program; } }
        // chain statements / IfStmt / Break / Continue / Return (NOT VarAssign).
        public List<Node> Plans { get; set; } = new List<Node>();
        public OutputRefNode Render { get; set; }                 // may be null
        public List<VarAssignNode> Vars { get; set; }              // null if no `let`
        public List<string> TrailingComments { get; set; }         // null if none
        public NamespaceMeta Namespace { get; set; }               // always present
    }

    // ---- Statements (reference/01 §6.2) --------------------------------------

    public sealed class VarAssignNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.VarAssign; } }
        public string Name { get; set; }
        public Node Expr { get; set; }
    }

    public sealed class IfStmtNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.IfStmt; } }
        public Node Condition { get; set; }
        public List<Node> Then { get; set; } = new List<Node>();
        public List<ElifClause> Elif { get; set; } = new List<ElifClause>();
        public List<Node> Else { get; set; }    // null when absent
    }

    public sealed class ElifClause
    {
        public Node Condition { get; set; }
        public List<Node> Then { get; set; } = new List<Node>();
    }

    public sealed class BreakNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Break; } }
    }

    public sealed class ContinueNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Continue; } }
    }

    public sealed class ReturnNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Return; } }
        public Node Value { get; set; }   // null when no expression
    }

    // The common case: { chain, write, write3d } — no `type` in reference (§6.2).
    public sealed class ChainStatementNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.ChainStatement; } }
        public List<Node> Chain { get; set; } = new List<Node>();
        // SurfaceRefNode (OutputRef/Xyz/Vel/Rgba/Mesh) when terminal Write; else null.
        public Node Write { get; set; }
        public Write3DTarget Write3d { get; set; }   // null unless terminal Write3D
    }

    public sealed class Write3DTarget
    {
        public Node Tex3d { get; set; }   // Ident | OutputRef | VolRef
        public Node Geo { get; set; }     // Ident | OutputRef | GeoRef
    }

    // ---- Chain elements (reference/01 §6.3) ----------------------------------

    public sealed class CallNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Call; } }
        public string Name { get; set; }
        public List<Node> Args { get; set; } = new List<Node>();
        // null when the call used positional args; an ordered map when keyword args.
        public OrderedKwargs Kwargs { get; set; }
        public NamespaceOverride Namespace { get; set; }   // from `from(...)`; else null
    }

    // Insertion-ordered kwargs (JS object key order is parity-significant: it drives
    // the "unknown argument" sweep order, reference/02 §6.14).
    public sealed class OrderedKwargs
    {
        private readonly List<string> _keys = new List<string>();
        private readonly Dictionary<string, Node> _map = new Dictionary<string, Node>();

        public int Count { get { return _keys.Count; } }
        public IReadOnlyList<string> Keys { get { return _keys; } }

        public void Set(string key, Node value)
        {
            if (!_map.ContainsKey(key)) _keys.Add(key);
            _map[key] = value;
        }
        public bool Has(string key) { return _map.ContainsKey(key); }
        public bool TryGet(string key, out Node value) { return _map.TryGetValue(key, out value); }
        public Node Get(string key) { Node v; return _map.TryGetValue(key, out v) ? v : null; }

        // JS `delete kwargs[key]` — used by param-alias resolution (reference/01 §8.5).
        // Removes the key and preserves the order of remaining keys.
        public void Remove(string key)
        {
            if (_map.Remove(key)) _keys.Remove(key);
        }
    }

    // from() namespace override (reference/01 §4.6).
    public sealed class NamespaceOverride
    {
        public string Name { get; set; }
        public List<string> Path { get; set; }
        public bool Explicit { get; set; }
        public string Source { get; set; }     // "from"
        public string Resolved { get; set; }
        public List<string> SearchOrder { get; set; }
        public bool FromOverride { get; set; }
    }

    public sealed class WriteNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Write; } }
        public Node Surface { get; set; }   // OutputRef|Xyz|Vel|Rgba|Mesh, or OutputRef{none}
    }

    public sealed class Write3DNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Write3D; } }
        public Node Tex3d { get; set; }
        public Node Geo { get; set; }
    }

    public sealed class SubchainNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Subchain; } }
        public string Name { get; set; }   // may be null
        public string Id { get; set; }     // may be null
        // DSL LOOPS: optional iteration count. A `subchain(iterations: N) { ... }`
        // bracket re-runs the enclosed sub-chain N times with per-iteration ping-pong
        // (reference §10.6). Null/1 means a plain (passthrough) subchain group, which
        // is the reference-exact behavior for `loopBegin()/loopEnd()` accumulators.
        public int? Iterations { get; set; } // null when absent
        public List<Node> Body { get; set; } = new List<Node>();
    }

    public sealed class ReadNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Read; } }
        public Node Surface { get; set; }   // ExprNode | null
        public bool Skip { get; set; }      // _skip
    }

    public sealed class Read3DNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Read3D; } }
        public Node Tex3d { get; set; }
        public Node Geo { get; set; }       // null for single-arg form
        public bool Skip { get; set; }
    }

    // ---- Expression value nodes (reference/01 §6.4) --------------------------

    public sealed class NumberNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Number; } }
        public double Value { get; set; }
        // Round-trip marker set by the validator's substitute() (reference/02 §2.10 H16).
        public string VarRef { get; set; }
    }

    public sealed class StringNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.String; } }
        public string Value { get; set; }   // raw, un-unescaped
    }

    public sealed class BooleanNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Boolean; } }
        public bool Value { get; set; }
    }

    public sealed class ColorNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Color; } }
        public double[] Value { get; set; }   // [r,g,b,a] in 0..1
    }

    public sealed class ArrayLiteralNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.ArrayLiteral; } }
        public List<Node> Elements { get; set; } = new List<Node>();
    }

    public sealed class FuncNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Func; } }
        public string Src { get; set; }   // arrow-fn body source text
    }

    public sealed class IdentNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Ident; } }
        public string Name { get; set; }
        public string VarRef { get; set; }
    }

    public sealed class MemberNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Member; } }
        public List<string> Path { get; set; } = new List<string>();   // >= 2 segments
        public string VarRef { get; set; }
    }

    // {type:'Chain', chain} value wrapper (only for multi-element chains, reference §4.5).
    public sealed class ChainNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Chain; } }
        public List<Node> Chain { get; set; } = new List<Node>();
    }

    // Surface refs. `Name` is the full lexeme (e.g. "o0", "vol3", "rgba1").
    public sealed class SurfaceRefNode : Node
    {
        private readonly NodeKind _kind;
        public override NodeKind Kind { get { return _kind; } }
        public string Name { get; set; }
        public SurfaceRefNode(NodeKind kind) { _kind = kind; }
    }

    public sealed class OutputRefNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.OutputRef; } }
        public string Name { get; set; }
    }

    // ---- Synthesized special nodes (reference/01 §6.5 / §7) -------------------

    public sealed class OscillatorNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Oscillator; } }
        public Node OscType { get; set; }
        public Node Min { get; set; }
        public Node Max { get; set; }
        public Node Speed { get; set; }
        public Node Offset { get; set; }
        public Node Seed { get; set; }
        public string VarRef { get; set; }
    }

    public sealed class MidiNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Midi; } }
        public Node Channel { get; set; }
        public Node Mode { get; set; }
        public Node Min { get; set; }
        public Node Max { get; set; }
        public Node Sensitivity { get; set; }
        public string VarRef { get; set; }
    }

    public sealed class AudioNode : Node
    {
        public override NodeKind Kind { get { return NodeKind.Audio; } }
        public Node Band { get; set; }
        public Node Min { get; set; }
        public Node Max { get; set; }
        public string VarRef { get; set; }
    }
}
