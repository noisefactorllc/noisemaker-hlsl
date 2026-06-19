// Enums.cs — stdEnums tree + dynamic enum/namespace registries (reference/01 §8).
//
// The reference enum tree (shaders/src/lang/std_enums.js) maps dotted member paths
// (e.g. ["oscKind","sine"]) to integer leaf values. enums.js layers effect-contributed
// enums on top; this port exposes a mutable registry the EffectRegistry can populate
// with effect `choices` (registerEnumPath), matching mergeIntoEnums semantics
// (reference/01 §8.2): an object WITH a numeric leaf is never merged into.
//
// PARITY HAZARDS replicated:
//  - palette enum values are POSITIONAL indices into share/palettes.json key order,
//    0-based, INCLUDING "none" at index 0 (reference/01 §8.1 / reference/03 §8). The
//    key order below is copied verbatim from share/palettes.json (56 entries).
//  - oscKind.noise == oscKind.noise1d == 5 (reference/01 §8.1).
//  - VALID_NAMESPACES is runtime-populated (reference/01 §3.2 hazard): the namespace
//    registry must be filled from the effect manifest before parsing `search`.
//
// Pure C#, no UnityEngine.

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler
{
    // An enum node is either a numeric leaf (HasValue) or a subtree (Children),
    // mirroring the reference {type:'Number', value:int} leaf vs nested-object subtree.
    public sealed class EnumNode
    {
        public bool HasValue { get; private set; }
        public double Value { get; private set; }
        public OrderedMapLite<string, EnumNode> Children { get; private set; }

        public static EnumNode Leaf(double value)
        {
            return new EnumNode { HasValue = true, Value = value };
        }
        public static EnumNode Tree()
        {
            return new EnumNode { HasValue = false, Children = new OrderedMapLite<string, EnumNode>() };
        }
    }

    // Minimal insertion-ordered map (avoids depending on the Graph namespace OrderedMap
    // since this asmdef is independent; semantics are identical).
    public sealed class OrderedMapLite<TKey, TValue>
    {
        private readonly List<TKey> _keys = new List<TKey>();
        private readonly Dictionary<TKey, TValue> _map = new Dictionary<TKey, TValue>();
        public int Count { get { return _keys.Count; } }
        public IReadOnlyList<TKey> Keys { get { return _keys; } }
        public void Set(TKey k, TValue v)
        {
            if (!_map.ContainsKey(k)) _keys.Add(k);
            _map[k] = v;
        }
        public bool Has(TKey k) { return _map.ContainsKey(k); }
        public bool TryGet(TKey k, out TValue v) { return _map.TryGetValue(k, out v); }
        public TValue Get(TKey k) { TValue v; return _map.TryGetValue(k, out v) ? v : default(TValue); }
    }

    public static class Enums
    {
        // share/palettes.json key order (verbatim, 0-based positional enum). The leading
        // "none" IS index 0 (reference/01 §8.1: palette enum from Object.keys order).
        public static readonly string[] PaletteKeys = new[]
        {
            "none", "seventiesShirt", "fiveG", "afterimage", "barstow", "bloob",
            "blueSkies", "brushedMetal", "burningSky", "california", "columbia",
            "cottonCandy", "darkSatin", "dealerHat", "dreamy", "eventHorizon",
            "ghostly", "grayscale", "hazySunset", "heatmap", "hypercolor", "jester",
            "justBlue", "justCyan", "justGreen", "justPurple", "justRed", "justYellow",
            "mars", "modesto", "moss", "neptune", "netOfGems", "organic", "papaya",
            "radioactive", "royal", "santaCruz", "sherbet", "sherbetDouble", "silvermane",
            "skykissed", "solaris", "spooky", "springtime", "sproingtime", "sulphur",
            "summoning", "superhero", "toxic", "tropicalia", "tungsten", "vaporwave",
            "vibrant", "vintage", "vintagePhoto"
        };

        // The std enum tree (reference/01 §8.1). Built once.
        private static readonly OrderedMapLite<string, EnumNode> _std = BuildStd();

        // Effect-contributed enums (reference/01 §8.2). Populated at load time.
        private static readonly OrderedMapLite<string, EnumNode> _project =
            new OrderedMapLite<string, EnumNode>();

        public static OrderedMapLite<string, EnumNode> Std { get { return _std; } }
        public static OrderedMapLite<string, EnumNode> Project { get { return _project; } }

        // Look up a top-level enum head: PROJECT enums take precedence over std (matching
        // resolveEnum's `enums` (project) checked before `stdEnums`, reference/02 §2.5).
        public static bool TryGetHead(string head, out EnumNode node)
        {
            if (_project.TryGet(head, out node)) return true;
            return _std.TryGet(head, out node);
        }

        // Register a nested enum path with a numeric leaf, e.g.
        // RegisterChoice("filter","blur","mode","gaussian", 0). Creates intermediate
        // subtrees. Used by EffectRegistry to install effect `choices` (reference/01 §8).
        public static void RegisterChoice(IReadOnlyList<string> path, double value)
        {
            if (path == null || path.Count == 0) return;
            EnumNode head;
            if (!_project.TryGet(path[0], out head) || head == null || head.HasValue)
            {
                head = EnumNode.Tree();
                _project.Set(path[0], head);
            }
            EnumNode cur = head;
            for (int i = 1; i < path.Count - 1; i++)
            {
                EnumNode next;
                if (!cur.Children.TryGet(path[i], out next) || next == null || next.HasValue)
                {
                    next = EnumNode.Tree();
                    cur.Children.Set(path[i], next);
                }
                cur = next;
            }
            cur.Children.Set(path[path.Count - 1], EnumNode.Leaf(value));
        }

        private static OrderedMapLite<string, EnumNode> BuildStd()
        {
            var root = new OrderedMapLite<string, EnumNode>();

            var channel = EnumNode.Tree();
            channel.Children.Set("r", EnumNode.Leaf(0));
            channel.Children.Set("g", EnumNode.Leaf(1));
            channel.Children.Set("b", EnumNode.Leaf(2));
            channel.Children.Set("a", EnumNode.Leaf(3));
            root.Set("channel", channel);

            var color = EnumNode.Tree();
            color.Children.Set("mono", EnumNode.Leaf(0));
            color.Children.Set("rgb", EnumNode.Leaf(1));
            color.Children.Set("hsv", EnumNode.Leaf(2));
            root.Set("color", color);

            var oscType = EnumNode.Tree();
            oscType.Children.Set("sine", EnumNode.Leaf(0));
            oscType.Children.Set("linear", EnumNode.Leaf(1));
            oscType.Children.Set("sawtooth", EnumNode.Leaf(2));
            oscType.Children.Set("sawtoothInv", EnumNode.Leaf(3));
            oscType.Children.Set("square", EnumNode.Leaf(4));
            oscType.Children.Set("noise1d", EnumNode.Leaf(5));
            oscType.Children.Set("noise2d", EnumNode.Leaf(6));
            root.Set("oscType", oscType);

            var oscKind = EnumNode.Tree();
            oscKind.Children.Set("sine", EnumNode.Leaf(0));
            oscKind.Children.Set("tri", EnumNode.Leaf(1));
            oscKind.Children.Set("saw", EnumNode.Leaf(2));
            oscKind.Children.Set("sawInv", EnumNode.Leaf(3));
            oscKind.Children.Set("square", EnumNode.Leaf(4));
            oscKind.Children.Set("noise", EnumNode.Leaf(5));    // alias of noise1d
            oscKind.Children.Set("noise1d", EnumNode.Leaf(5));
            oscKind.Children.Set("noise2d", EnumNode.Leaf(6));
            root.Set("oscKind", oscKind);

            var midiMode = EnumNode.Tree();
            midiMode.Children.Set("noteChange", EnumNode.Leaf(0));
            midiMode.Children.Set("gateNote", EnumNode.Leaf(1));
            midiMode.Children.Set("gateVelocity", EnumNode.Leaf(2));
            midiMode.Children.Set("triggerNote", EnumNode.Leaf(3));
            midiMode.Children.Set("velocity", EnumNode.Leaf(4));
            root.Set("midiMode", midiMode);

            var audioBand = EnumNode.Tree();
            audioBand.Children.Set("low", EnumNode.Leaf(0));
            audioBand.Children.Set("mid", EnumNode.Leaf(1));
            audioBand.Children.Set("high", EnumNode.Leaf(2));
            audioBand.Children.Set("vol", EnumNode.Leaf(3));
            root.Set("audioBand", audioBand);

            var palette = EnumNode.Tree();
            for (int idx = 0; idx < PaletteKeys.Length; idx++)
                palette.Children.Set(PaletteKeys[idx], EnumNode.Leaf(idx));
            root.Set("palette", palette);

            return root;
        }
    }
}
