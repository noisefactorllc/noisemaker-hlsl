// TextureSpec.cs — a pooled / declared / global-override texture spec.
//
// Schema (GRAPH-JSON-SCHEMA.md "TextureSpec & dimensions", reference/03 §2.4):
//   { "width": <Dim>, "height": <Dim>, "depth"?: <Dim>, "is3D"?: bool,
//     "format"?: "rgba16f" }
//
// Width/Height are always present in emitted graphs. Depth is present only for 3D
// volumes. Is3D is true for 3D textures. Format defaults to "rgba16f" when absent
// (the DEFAULT is applied by the pipeline, NOT here — Format stays null if the
// JSON omits it, so the runtime can apply its own default and round-trip exactly).

namespace Noisemaker.Hlsl.Compiler.Graph
{
    public sealed class TextureSpec
    {
        public Dim Width { get; set; }
        public Dim Height { get; set; }
        public Dim Depth { get; set; }      // null when 2D
        public bool Is3D { get; set; }       // false when absent
        public string Format { get; set; }   // null when absent; pipeline defaults to "rgba16f"
    }
}
