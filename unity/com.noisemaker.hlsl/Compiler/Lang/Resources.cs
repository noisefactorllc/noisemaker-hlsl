// Resources.cs — liveness analysis + linear-scan texture pooling, a 1:1 port of
// shaders/src/runtime/resources.js (reference/04 §1).
//
// Lives in the compiler (graph construction): allocateResources(passes) maps virtual
// pooled texIds to physical slots "phys_N". This is the producer of RenderGraph.Allocations.
//
// PARITY-CRITICAL (reference/04 §1.3, §14.4 / hazard 9):
//  - Allocation order within a pass follows Object.values(pass.outputs) INSERTION order;
//    release follows Object.values(pass.inputs) order. OrderedMap preserves this.
//  - Output allocation happens BEFORE input release in the same pass, so a tex read and
//    written at pass i cannot reuse its own slot (availableAfter=i is not < i).
//  - Free slot search picks the FIRST freeList entry with availableAfter < i.
//  - Only 'global_'-prefixed ids are excluded (infinite-lived).
//  - Fully deterministic, no float math.
//
// Pure C#, no UnityEngine. Operates on Graph.Pass (Inputs/Outputs OrderedMaps).

using System.Collections.Generic;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl.Compiler
{
    public static class Resources
    {
        private struct Lifetime { public int Start; public int End; }
        private struct FreeSlot { public string Id; public int AvailableAfter; }

        // reference/04 §1.1 analyzeLiveness.
        private static Dictionary<string, Lifetime> AnalyzeLiveness(IReadOnlyList<Pass> passes)
        {
            var lifetime = new Dictionary<string, Lifetime>();
            void Touch(string texId, int index)
            {
                if (string.IsNullOrEmpty(texId)) return;
                if (texId.StartsWith("global_")) return; // globals are infinite-lived
                Lifetime l;
                if (!lifetime.TryGetValue(texId, out l))
                    lifetime[texId] = new Lifetime { Start = index, End = index };
                else
                {
                    if (index < l.Start) l.Start = index;
                    if (index > l.End) l.End = index;
                    lifetime[texId] = l;
                }
            }

            for (int index = 0; index < passes.Count; index++)
            {
                Pass pass = passes[index];
                if (pass.Inputs != null)
                    foreach (string tex in pass.Inputs.Values) Touch(tex, index);
                if (pass.Outputs != null)
                    foreach (string tex in pass.Outputs.Values) Touch(tex, index);
            }
            return lifetime;
        }

        // reference/04 §1.2 allocateResources. Returns texId -> "phys_N".
        public static OrderedMap<string, string> AllocateResources(IReadOnlyList<Pass> passes)
        {
            Dictionary<string, Lifetime> lifetime = AnalyzeLiveness(passes);
            var allocations = new OrderedMap<string, string>();
            var freeList = new List<FreeSlot>();
            int physicalCount = 0;

            for (int i = 0; i < passes.Count; i++)
            {
                Pass pass = passes[i];

                // 1. Allocate outputs (definitions).
                if (pass.Outputs != null)
                {
                    foreach (string texId in pass.Outputs.Values)
                    {
                        if (texId == null) continue;
                        if (texId.StartsWith("global_")) continue;
                        if (allocations.ContainsKey(texId)) continue;

                        int freeIdx = -1;
                        for (int k = 0; k < freeList.Count; k++)
                            if (freeList[k].AvailableAfter < i) { freeIdx = k; break; }

                        if (freeIdx != -1)
                        {
                            FreeSlot item = freeList[freeIdx];
                            freeList.RemoveAt(freeIdx);
                            allocations.Add(texId, item.Id);
                        }
                        else
                        {
                            string id = "phys_" + physicalCount++;
                            allocations.Add(texId, id);
                        }
                    }
                }

                // 2. Release inputs (last uses).
                if (pass.Inputs != null)
                {
                    foreach (string texId in pass.Inputs.Values)
                    {
                        if (texId == null) continue;
                        if (texId.StartsWith("global_")) continue;
                        Lifetime l;
                        if (lifetime.TryGetValue(texId, out l) && l.End == i)
                        {
                            string physId;
                            if (allocations.TryGetValue(texId, out physId))
                                freeList.Add(new FreeSlot { Id = physId, AvailableAfter = i });
                        }
                    }
                }
            }
            return allocations;
        }
    }
}
