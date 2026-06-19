#ifndef NM_SG_GRAIN_INCLUDED
#define NM_SG_GRAIN_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/grain.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   alpha -> Alpha (float) [0,1] default 0.25
//   pause -> Pause (float, 0/1) default 0
// Time is an engine global in the runtime path; here it is an explicit Time
// input (normalized 0..1 animation time) so the node is self-contained.
// InputTex/SS/UV provide the source surface; integer pixel coords for the noise
// lattice are reconstructed as floor(UV * dims), matching the WGSL gid.xy.
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl). Helpers and
// core are mirrored VERBATIM from Shaders/Effects/filter/Grain.hlsl, name-
// prefixed `nmsg_` to avoid symbol clashes with the runtime include.
//
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state to match the
// runtime bilinear/clamp/linear path (H7).
// TODO(verify): RenderScale defaults to 1.0 here (untiled). The noise frequency
// uses dims = texDims; in the multi-tile runtime path dims is divided by
// renderScale. Single-node SG usage is untiled, so this matches.
// =============================================================================

static const float NMSG_GRAIN_PI   = 3.14159265358979323846;
static const float NMSG_GRAIN_TAU  = 6.28318530717958647692;
static const float NMSG_GRAIN_UINT32_TO_FLOAT = 1.0 / 4294967296.0;
static const uint  NMSG_GRAIN_INTERPOLATION_BICUBIC = 3u;
static const uint  NMSG_GRAIN_BASE_SEED = 0x1234u;

float nmsg_grain_clamp01(float value)
{
    return clamp(value, 0.0, 1.0);
}

uint3 nmsg_grain_pcg3d(uint3 v_in)
{
    uint3 v = v_in * 1664525u + 1013904223u;
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    v = v ^ (v >> uint3(16u, 16u, 16u));
    v.x = v.x + v.y * v.z;
    v.y = v.y + v.z * v.x;
    v.z = v.z + v.x * v.y;
    return v;
}

float nmsg_grain_random_from_cell_3d(int3 cell, uint seed)
{
    uint3 hashed = uint3(
        (uint)cell.x ^ seed,
        (uint)cell.y ^ (seed * 0x9e3779b9u + 0x7f4a7c15u),
        (uint)cell.z ^ (seed * 0x632be59bu + 0x5bf03635u)
    );
    uint3 noise = nmsg_grain_pcg3d(hashed);
    return (float)noise.x * NMSG_GRAIN_UINT32_TO_FLOAT;
}

float nmsg_grain_periodic_value(float time_value, float sample_val)
{
    return (sin((time_value - sample_val) * NMSG_GRAIN_TAU) + 1.0) * 0.5;
}

float nmsg_grain_blend_cubic(float a, float b, float c, float d, float g)
{
    float t = clamp(g, 0.0, 1.0);
    float t2 = t * t;
    float a0 = ((d - c) - a) + b;
    float a1 = (a - b) - a0;
    float a2 = c - a;
    float a3 = b;
    float term1 = (a0 * t) * t2;
    float term2 = a1 * t2;
    float term3 = (a2 * t) + a3;
    return (term1 + term2) + term3;
}

float nmsg_grain_sample_bicubic_layer(int2 cell, float2 frac_uv, int z_cell, uint base_seed)
{
    float row0 = nmsg_grain_blend_cubic(
        nmsg_grain_random_from_cell_3d(int3(cell.x - 1, cell.y - 1, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 0, cell.y - 1, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 1, cell.y - 1, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 2, cell.y - 1, z_cell), base_seed),
        frac_uv.x
    );
    float row1 = nmsg_grain_blend_cubic(
        nmsg_grain_random_from_cell_3d(int3(cell.x - 1, cell.y + 0, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 0, cell.y + 0, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 1, cell.y + 0, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 2, cell.y + 0, z_cell), base_seed),
        frac_uv.x
    );
    float row2 = nmsg_grain_blend_cubic(
        nmsg_grain_random_from_cell_3d(int3(cell.x - 1, cell.y + 1, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 0, cell.y + 1, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 1, cell.y + 1, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 2, cell.y + 1, z_cell), base_seed),
        frac_uv.x
    );
    float row3 = nmsg_grain_blend_cubic(
        nmsg_grain_random_from_cell_3d(int3(cell.x - 1, cell.y + 2, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 0, cell.y + 2, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 1, cell.y + 2, z_cell), base_seed),
        nmsg_grain_random_from_cell_3d(int3(cell.x + 2, cell.y + 2, z_cell), base_seed),
        frac_uv.x
    );
    return nmsg_grain_blend_cubic(row0, row1, row2, row3, frac_uv.y);
}

float nmsg_grain_sample_raw_value_noise(
    float2 uv,
    float2 freq,
    uint base_seed,
    float time_value,
    float speed_value,
    uint spline_order)
{
    float2 scaled_freq = max(freq, float2(1.0, 1.0));
    float2 scaled_uv = uv * scaled_freq;
    float2 cell_f = floor(scaled_uv);
    int2 cell = int2((int)cell_f.x, (int)cell_f.y);
    float2 frac_uv = frac(scaled_uv);
    float angle = time_value * NMSG_GRAIN_TAU;
    float time_coord = cos(angle) * speed_value;
    float time_floor = floor(time_coord);
    int time_cell = (int)time_floor;
    float time_frac = frac(time_coord);

    // Grain always uses the bicubic spline order (INTERPOLATION_BICUBIC).
    float slice0 = nmsg_grain_sample_bicubic_layer(cell, frac_uv, time_cell - 1, base_seed);
    float slice1 = nmsg_grain_sample_bicubic_layer(cell, frac_uv, time_cell + 0, base_seed);
    float slice2 = nmsg_grain_sample_bicubic_layer(cell, frac_uv, time_cell + 1, base_seed);
    float slice3 = nmsg_grain_sample_bicubic_layer(cell, frac_uv, time_cell + 2, base_seed);
    return nmsg_grain_blend_cubic(slice0, slice1, slice2, slice3, time_frac);
}

float nmsg_grain_sample_value_noise(
    float2 uv,
    float2 freq,
    uint seed,
    float time_value,
    float speed_value,
    uint spline_order)
{
    uint base_seed = seed;
    float base_value = nmsg_grain_sample_raw_value_noise(
        uv, freq, base_seed, time_value, speed_value, spline_order);

    if (speed_value == 0.0 || time_value == 0.0)
    {
        return base_value;
    }

    uint time_seed = base_seed + 0x9e3779b1u;
    float time_field = nmsg_grain_sample_raw_value_noise(
        uv, freq, time_seed, 0.0, 1.0, spline_order);
    float scaled_time = nmsg_grain_periodic_value(time_value, time_field) * speed_value;
    return nmsg_grain_periodic_value(scaled_time, base_value);
}

float nmsg_grain_sample_grain_noise(
    uint2 pixel_coords,
    float2 dims,
    float time_value,
    float speed_value)
{
    float width = max(dims.x, 1.0);
    float height = max(dims.y, 1.0);
    float2 uv = float2((float)pixel_coords.x / width, (float)pixel_coords.y / height);
    float2 freq = float2(width, height);
    return nmsg_grain_sample_value_noise(uv, freq, NMSG_GRAIN_BASE_SEED, time_value, speed_value, NMSG_GRAIN_INTERPOLATION_BICUBIC);
}

// Shader Graph Custom Function entry. Samples InputTex at UV, derives dims and
// integer pixel coords from the bound texture, then applies the grain blend.
void NM_Grain_float(
    UnityTexture2D InputTex,
    UnitySamplerState SS,
    float2         UV,
    float          Time,
    float          Alpha,
    float          Pause,
    out float4     Out)
{
    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 dims = float2(texW, texH);

    float4 texel = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);

    float blend_alpha = clamp(Alpha, 0.0, 1.0);
    if (blend_alpha <= 0.0)
    {
        Out = texel;
        return;
    }

    // Reconstruct integer pixel coords (WGSL gid.xy) from UV * dims.
    uint2 pixel_coords = uint2((uint)floor(UV.x * dims.x), (uint)floor(UV.y * dims.y));

    float effective_time = (Pause > 0.5) ? 0.0 : Time;

    float noise_value = nmsg_grain_sample_grain_noise(pixel_coords, dims, effective_time, 100.0);
    float3 noise_rgb = float3(noise_value, noise_value, noise_value);
    float3 mixed_rgb = lerp(texel.rgb, noise_rgb, blend_alpha);
    Out = float4(
        nmsg_grain_clamp01(mixed_rgb.x),
        nmsg_grain_clamp01(mixed_rgb.y),
        nmsg_grain_clamp01(mixed_rgb.z),
        texel.a
    );
}

#endif // NM_SG_GRAIN_INCLUDED
