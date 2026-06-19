// TextureStore.cs — owns the pooled physical RenderTextures (phys_N) and the raw
// RT factory used by SurfaceManager too. Mirrors reference/04 §1 (pooling), §8
// (formats) and §9 (resolveDimension + recreateTextures size logic).
//
// The runtime never re-runs the JS liveness allocator: the normalized graph JSON
// already carries graph.allocations (virtual texId -> "phys_N"). So this store:
//   * resolves a virtual/pooled texId to its physical slot id via allocations,
//   * creates exactly one RenderTexture per distinct phys_N (sized from the spec
//     of one of the texIds mapped to it — they share a slot only when liveness
//     proved compatible sizes, so any mapped spec is representative),
//   * resolves dimensions with the EXACT reference rounding rules.
//
// Formats (GRAPH-JSON-SCHEMA.md "## Formats", reference/04 §8): rgba16f->ARGBHalf,
// rgba32f->ARGBFloat, rgba8->ARGB32. ALL created RenderTextureReadWrite.Linear,
// 4-channel, no sRGB. Surfaces that compute passes write also need enableRandomWrite
// = false (we use fragment MRT, not UAV) but DO need to be valid render targets;
// bilinear clamp filter to match the reference sampler defaults.

using System.Collections.Generic;
using UnityEngine;
using Noisemaker.Hlsl.Compiler.Graph;

namespace Noisemaker.Hlsl
{
    public sealed class TextureStore
    {
        // texId / surface-buffer-id -> RenderTexture handle.
        private readonly Dictionary<string, RenderTexture> _textures =
            new Dictionary<string, RenderTexture>();

        public int ScreenWidth { get; private set; }
        public int ScreenHeight { get; private set; }

        public void SetScreenSize(int w, int h)
        {
            ScreenWidth = Mathf.Max(1, w);
            ScreenHeight = Mathf.Max(1, h);
        }

        public RenderTexture Get(string id)
        {
            RenderTexture rt;
            return _textures.TryGetValue(id, out rt) ? rt : null;
        }

        public bool Has(string id) { return _textures.ContainsKey(id); }

        public IEnumerable<string> Keys { get { return _textures.Keys; } }

        // ---- format map (reference/04 §8) ---------------------------------
        public static RenderTextureFormat MapFormat(string format)
        {
            // Default rgba16f when absent (pipeline default, GRAPH-JSON-SCHEMA §Formats).
            if (string.IsNullOrEmpty(format)) return RenderTextureFormat.ARGBHalf;
            switch (format)
            {
                case "rgba16f":
                case "rgba16float":
                    return RenderTextureFormat.ARGBHalf;
                case "rgba32f":
                case "rgba32float":
                    return RenderTextureFormat.ARGBFloat;
                case "rgba8":
                case "rgba8unorm":
                    return RenderTextureFormat.ARGB32;
                default:
                    return RenderTextureFormat.ARGBHalf;
            }
        }

        // ---- resolveDimension (reference/04 §9, EXACT) --------------------
        // screenSize is W for width dims, H for height dims; uniforms supplies param/
        // screenDivide values. Returns an int >= 1.
        public static int ResolveDimension(Dim spec, int screenSize,
            System.Func<string, double?> uniformLookup)
        {
            if (spec == null) return Mathf.Max(1, screenSize);

            switch (spec.Kind)
            {
                case DimKind.Number:
                    // number -> max(1, floor(spec))
                    return Mathf.Max(1, (int)System.Math.Floor(spec.Number));

                case DimKind.Screen:
                    // 'screen' / 'auto' -> screenSize
                    return Mathf.Max(1, screenSize);

                case DimKind.Percent:
                    // "p%" -> max(1, floor(screenSize * p / 100))
                    return Mathf.Max(1, (int)System.Math.Floor(
                        screenSize * spec.Percent / 100.0));

                case DimKind.Param:
                {
                    // hasTransform = power!=undefined || multiply!=undefined
                    bool hasTransform = spec.Power.HasValue || spec.Multiply.HasValue;
                    // paramDefault = spec.paramDefault ?? 64
                    double paramDefault = spec.ParamDefault.HasValue ? spec.ParamDefault.Value : 64.0;
                    double? u = uniformLookup != null ? uniformLookup(spec.Param) : null;
                    double value = u.HasValue ? u.Value : paramDefault;
                    if (spec.Multiply.HasValue) value *= spec.Multiply.Value;
                    if (spec.Power.HasValue) value = System.Math.Pow(value, spec.Power.Value);
                    // hasTransform && uniforms[param]===undefined && spec.default!==undefined
                    if (hasTransform && !u.HasValue && spec.DefaultValue.HasValue)
                        value = spec.DefaultValue.Value;
                    return Mathf.Max(1, (int)System.Math.Floor(value));
                }

                case DimKind.ScreenDivide:
                {
                    // divisor = uniforms[screenDivide] ?? spec.default ?? 1
                    double? u = uniformLookup != null ? uniformLookup(spec.ScreenDivide) : null;
                    double divisor = u.HasValue ? u.Value
                        : (spec.DefaultValue.HasValue ? spec.DefaultValue.Value : 1.0);
                    if (divisor == 0.0) divisor = 1.0; // guard div-by-zero (JS would yield Infinity)
                    // ROUND, not floor.
                    return Mathf.Max(1, (int)System.Math.Round(
                        screenSize / divisor, System.MidpointRounding.AwayFromZero));
                    // TODO(verify): JS Math.round rounds .5 toward +Inf; .NET AwayFromZero
                    // matches for positive operands (all sizes positive).
                }

                case DimKind.Scale:
                {
                    // computed = floor(screenSize*scale); clamp; max(1,..)
                    double computed = System.Math.Floor(screenSize * spec.Scale);
                    if (spec.ClampMin.HasValue) computed = System.Math.Max(computed, spec.ClampMin.Value);
                    if (spec.ClampMax.HasValue) computed = System.Math.Min(computed, spec.ClampMax.Value);
                    return Mathf.Max(1, (int)computed);
                }

                default:
                    return Mathf.Max(1, screenSize);
            }
        }

        // True if the dim forces recreation on resize (reference/04 isDynamicDimension:
        // a fixed Number is static; everything else depends on screen/uniforms).
        public static bool IsDynamic(Dim spec)
        {
            if (spec == null) return true;
            return spec.Kind != DimKind.Number;
        }

        // VOLUME ATLAS CONVENTION (reference/04 §8, render3d/renderLit3d/synth3d JSON).
        // The reference has NO true 3D sampler in the volume path: every "3D" volume is
        // a 2D ATLAS RenderTexture of `volumeSize` x `volumeSize^2` (default 64 x 4096 =
        // 64 stacked slices of 64x64), rgba16f LINEAR. Both the synth3d/filter3d WRITERS
        // and the render3d/renderLit3d RAYMARCH consumers address it as a 2D texture by
        // INTEGER texel fetch:
        //     atlasTexel(voxel.xyz, volSize) = int2( voxel.x, voxel.y + voxel.z*volSize )
        //     density = volumeCache.Load(int3(atlasTexel, 0));   // point fetch, no filter
        // Trilinear filtering, when needed, is done MANUALLY in the shader (8-corner
        // fetch + lerp) — never via a hardware 3D sampler. A real UnityEngine Tex3D
        // (volumeDepth>1) is therefore WRONG here: it cannot be `.Load`-ed as a flat
        // 64x4096 sheet and would mis-address every voxel. We map an `is3D` graph spec
        // to a 2D RT sized width x height (the atlas dims the spec already carries:
        // width = volumeSize, height = volumeSize^2). `depth` is informational only.
        // TODO(verify): if a future effect needs a hardware Tex3D, gate it on an
        // explicit spec flag; none of the 13+ ported 3D effects do (all atlas).

        // Create (or reuse if size matches) an RT for a given id. Mirrors the
        // recreateTextures reuse rule: if an existing RT matches w/h keep it (preserves
        // sim/volume state); else destroy + recreate. `is3D` selects the 2D VOLUME-ATLAS
        // layout (see convention above); `depth` is recorded but the RT stays 2D.
        public RenderTexture CreateOrReuse(string id, int width, int height,
            string format, bool is3D, int depth)
        {
            RenderTexture existing;
            if (_textures.TryGetValue(id, out existing) && existing != null)
            {
                bool sizeMatch = existing.width == width && existing.height == height;
                // Atlas RTs are 2D; identity is fully determined by width/height
                // (height already encodes the slice stack volumeSize^2). Do NOT compare
                // volumeDepth — the atlas RT has volumeDepth==1 by construction.
                if (sizeMatch) return existing;
                Destroy(id);
            }

            var fmt = MapFormat(format);
            // ALWAYS a 2D RenderTexture, including the volume atlas (is3D). See the
            // VOLUME ATLAS CONVENTION above: the 64x4096 atlas is a 2D sheet, read by
            // integer texel fetch, NOT a hardware Tex3D.
            RenderTexture rt = new RenderTexture(
                width, height, 0, fmt, RenderTextureReadWrite.Linear);
            rt.name = "NM_" + id;
            rt.enableRandomWrite = false; // fragment MRT model, no UAV writes
            rt.useMipMap = false;
            rt.autoGenerateMips = false;
            // PARITY (webgl2.js createTexture, lines 221-224): the reference backend
            // creates EVERY surface/intermediate render texture with NEAREST filtering
            // and CLAMP_TO_EDGE wrap. Only externally-loaded video/image textures
            // (updateTextureFromSource) use LINEAR — those are a separate path (loaded
            // as Texture2D assets in Unity, not RenderTextures). Surfaces that get
            // sampled as `inputTex` MUST be point-sampled or transform/UV-remap effects
            // (scale/tile/pixels/seamless/refract/…) diverge by a bilinear-vs-nearest
            // delta at every fractional sample point.
            rt.filterMode = FilterMode.Point;     // reference surface sampler = NEAREST
            rt.wrapMode = TextureWrapMode.Clamp;  // reference surface wrap = CLAMP_TO_EDGE
            rt.Create();

            // PARITY (webgl2.js createFBO): every newly-created texture is cleared to
            // transparent black on creation. Persistent feedback/state textures
            // (_h1.._h8, _selfTex, _rollFb, global_*_state, ns_velocity/pressure) rely
            // on a known-zero initial frame (alpha==0 => "empty" fallback; sims start
            // clean). Unity does NOT zero a fresh RenderTexture, so clear explicitly.
            ClearToTransparentBlack(rt);

            _textures[id] = rt;
            return rt;
        }

        // Clear a render texture to transparent black (0,0,0,0). Matches the
        // reference webgl2 createFBO clear. ALL RTs here are 2D — including the 64x4096
        // volume atlas (see VOLUME ATLAS CONVENTION in CreateOrReuse) — so a single
        // GL.Clear fully zeroes the surface (every voxel slice) in one pass.
        private static void ClearToTransparentBlack(RenderTexture rt)
        {
            if (rt == null) return;
            RenderTexture prev = RenderTexture.active;
            RenderTexture.active = rt;
            GL.Clear(false, true, new Color(0f, 0f, 0f, 0f));
            RenderTexture.active = prev;
        }

        public void Destroy(string id)
        {
            RenderTexture rt;
            if (_textures.TryGetValue(id, out rt))
            {
                if (rt != null)
                {
                    rt.Release();
#if UNITY_EDITOR
                    Object.DestroyImmediate(rt);
#else
                    Object.Destroy(rt);
#endif
                }
                _textures.Remove(id);
            }
        }

        // Allocate one RenderTexture per distinct phys_N from graph.allocations.
        // Each phys slot is sized using the spec of (one of) the texIds bound to it.
        // The liveness allocator only shares a slot between texIds whose sizes are
        // compatible, so the first-seen spec is representative (reference/04 §1.3).
        public void AllocatePooled(RenderGraph graph, System.Func<string, double?> uniforms)
        {
            // phys_N -> already created flag (first spec wins, deterministic order).
            var seen = new HashSet<string>();
            foreach (var kv in graph.Allocations)
            {
                string virtualId = kv.Key;
                string physId = kv.Value;
                if (string.IsNullOrEmpty(physId)) continue;
                if (seen.Contains(physId)) continue;

                TextureSpec spec;
                if (!graph.Textures.TryGetValue(virtualId, out spec) || spec == null)
                    continue; // no spec -> created lazily on demand by ResolvePhysical

                int w = ResolveDimension(spec.Width, ScreenWidth, uniforms);
                int h = ResolveDimension(spec.Height, ScreenHeight, uniforms);
                int d = 1;
                if (spec.Is3D && spec.Depth != null)
                    d = ResolveDimension(spec.Depth, ScreenHeight, uniforms);

                CreateOrReuse(physId, w, h, spec.Format, spec.Is3D, d);
                seen.Add(physId);
            }
        }

        public void DestroyAll()
        {
            foreach (var rt in _textures.Values)
            {
                if (rt != null)
                {
                    rt.Release();
#if UNITY_EDITOR
                    Object.DestroyImmediate(rt);
#else
                    Object.Destroy(rt);
#endif
                }
            }
            _textures.Clear();
        }
    }
}
