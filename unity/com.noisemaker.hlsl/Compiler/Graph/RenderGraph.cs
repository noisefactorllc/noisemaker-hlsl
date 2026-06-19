// RenderGraph.cs — the shared C# render-graph data model.
//
// This is the seam (ARCHITECTURE.md "The seam: the Render Graph"): the single
// data contract that BOTH the runtime executor (Runtime/ asmdef) and the live DSL
// frontend (the C# Expander) produce/consume. It mirrors the normalized JSON in
// GRAPH-JSON-SCHEMA.md exactly.
//
//   id            : hashSource(dsl)
//   source        : the DSL text
//   renderSurface : surface presented to screen / output RT (e.g. "o0"); null if none
//   passes        : Pass[] in execution order (List preserves order)
//   textures      : texId -> TextureSpec (pooled + effect-declared + global_ overrides)
//   allocations   : virtual pooled texId -> physical slot id ("phys_N"); globals NOT here
//   programs      : programId -> Program (optional; for traceability / golden diff)
//
// OrderedMap is used for textures/allocations/programs because insertion order is
// parity-significant (phys_N numbering, golden-diff byte stability).

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler.Graph
{
    public sealed class RenderGraph
    {
        public string Id { get; set; }
        public string Source { get; set; }
        public string RenderSurface { get; set; }   // null when no surface is presented

        public List<Pass> Passes { get; set; } = new List<Pass>();

        public OrderedMap<string, TextureSpec> Textures { get; set; }
            = new OrderedMap<string, TextureSpec>();

        public OrderedMap<string, string> Allocations { get; set; }
            = new OrderedMap<string, string>();

        public OrderedMap<string, Program> Programs { get; set; }
            = new OrderedMap<string, Program>();

        // Convenience: parse a JSON string into a RenderGraph (delegates to GraphLoader).
        public static RenderGraph FromJson(string json)
        {
            return GraphLoader.FromJson(json);
        }
    }
}
