// OrderedMap<K,V> — an insertion-ordered dictionary.
//
// PARITY CRITICAL (reference/04 §1.3, §14.4): both phys_N pooling numbering and
// uniform fan-out depend on JS object insertion order. .NET's Dictionary<,> does
// NOT guarantee enumeration order, so the render-graph model uses this type
// everywhere the reference iterates a JS object/Map. Enumeration, Keys, Values,
// and indexed access all follow first-insertion order; re-assigning an existing
// key updates the value in place WITHOUT changing its position (matching JS
// `obj[k] = v` semantics).
//
// Pure C#. No UnityEngine, no external packages.

using System;
using System.Collections;
using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler.Graph
{
    public sealed class OrderedMap<TKey, TValue> : IEnumerable<KeyValuePair<TKey, TValue>>
    {
        private readonly List<KeyValuePair<TKey, TValue>> _entries;
        private readonly Dictionary<TKey, int> _index;

        public OrderedMap()
        {
            _entries = new List<KeyValuePair<TKey, TValue>>();
            _index = new Dictionary<TKey, int>();
        }

        public OrderedMap(IEqualityComparer<TKey> comparer)
        {
            _entries = new List<KeyValuePair<TKey, TValue>>();
            _index = new Dictionary<TKey, int>(comparer);
        }

        public int Count { get { return _entries.Count; } }

        // JS `obj[key] = value`: update in place if present (position preserved),
        // otherwise append at the end.
        public void Add(TKey key, TValue value)
        {
            int i;
            if (_index.TryGetValue(key, out i))
            {
                _entries[i] = new KeyValuePair<TKey, TValue>(key, value);
                return;
            }
            _index[key] = _entries.Count;
            _entries.Add(new KeyValuePair<TKey, TValue>(key, value));
        }

        public TValue this[TKey key]
        {
            get
            {
                int i;
                if (_index.TryGetValue(key, out i)) return _entries[i].Value;
                throw new KeyNotFoundException("OrderedMap has no key: " + key);
            }
            set { Add(key, value); }
        }

        public bool ContainsKey(TKey key)
        {
            return _index.ContainsKey(key);
        }

        public bool TryGetValue(TKey key, out TValue value)
        {
            int i;
            if (_index.TryGetValue(key, out i))
            {
                value = _entries[i].Value;
                return true;
            }
            value = default(TValue);
            return false;
        }

        // Nullish-style lookup helper: returns the value if present, else fallback.
        public TValue GetOrDefault(TKey key, TValue fallback)
        {
            int i;
            return _index.TryGetValue(key, out i) ? _entries[i].Value : fallback;
        }

        // Keys / Values in insertion order. Allocates; do not call in render loops.
        public IEnumerable<TKey> Keys
        {
            get
            {
                for (int i = 0; i < _entries.Count; i++) yield return _entries[i].Key;
            }
        }

        public IEnumerable<TValue> Values
        {
            get
            {
                for (int i = 0; i < _entries.Count; i++) yield return _entries[i].Value;
            }
        }

        // Index-positional access (insertion order). Used by liveness/pooling which
        // walks Object.values(pass.outputs) / pass.inputs in order.
        public KeyValuePair<TKey, TValue> EntryAt(int position)
        {
            return _entries[position];
        }

        public IEnumerator<KeyValuePair<TKey, TValue>> GetEnumerator()
        {
            return _entries.GetEnumerator();
        }

        IEnumerator IEnumerable.GetEnumerator()
        {
            return _entries.GetEnumerator();
        }
    }
}
