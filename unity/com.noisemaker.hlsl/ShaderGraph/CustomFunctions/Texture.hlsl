#ifndef NM_SG_TEXTURE_INCLUDED
#define NM_SG_TEXTURE_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/texture.
//
// Drops the effect into Shader Graph as a node. Each global param from
// definition.js maps to a named input:
//   mode  -> Mode  (float, runtime int 0..4) default 3 (paper)
//   alpha -> Alpha (float)                    [0,1] default 0.5
//   scale -> Scale (float)                    [0.1,10] default 1.0
//   time  -> Time  (float, engine global; 0..1 normalized animation time)
// InputTex/SS/UV provide the source surface. UV must be the fullscreen 0..1 UV
// (the WGSL uses `in.uv` for both the sample and the height-field domain).
//
// Single render pass — eligible for a Custom Function node (PORTING-GUIDE §1d).
//
// Self-contained (does NOT include NMFullscreen.hlsl / NMCore.hlsl) so it is
// safe to drop into a Shader Graph Custom Function node. Helpers/core are
// mirrored VERBATIM from Shaders/Effects/filter/Texture.hlsl, name-prefixed
// `nmsg_` to avoid symbol clashes with the runtime include.
// =============================================================================

static const float NMSG_TEX_PI = 3.14159265359;
static const float NMSG_TEX_INV_UINT32_MAX = 1.0 / 4294967295.0;
static const int   NMSG_TEX_Z_LOOP = 2;
static const float NMSG_TEX_SHADE_GAIN = 4.4;

float nmsg_texture_clamp01(float value)
{
    return clamp(value, 0.0, 1.0);
}

float nmsg_texture_fade(float t)
{
    return t * t * (3.0 - 2.0 * t);
}

float2 nmsg_texture_freq_for_shape(float base_freq, float2 dims)
{
    float w = max(dims.x, 1.0);
    float h = max(dims.y, 1.0);
    if (abs(w - h) < 0.5)
    {
        return float2(base_freq, base_freq);
    }
    if (w > h)
    {
        return float2(base_freq, base_freq * w / h);
    }
    return float2(base_freq * h / w, base_freq);
}

uint nmsg_texture_hash_uint(uint x_in)
{
    uint x = x_in;
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

float nmsg_texture_fast_hash(int3 p, uint salt)
{
    uint h = salt ^ 0x9e3779b9u;
    h ^= asuint(p.x) * 0x27d4eb2du;
    h = nmsg_texture_hash_uint(h);
    h ^= asuint(p.y) * 0xc2b2ae35u;
    h = nmsg_texture_hash_uint(h);
    h ^= asuint(p.z) * 0x165667b1u;
    h = nmsg_texture_hash_uint(h);
    return (float)h * NMSG_TEX_INV_UINT32_MAX;
}

float nmsg_texture_value_noise(float2 uv, float2 freq, float motion, uint salt)
{
    float2 scaled_uv = uv * max(freq, float2(1.0, 1.0));
    float2 cell_floor = floor(scaled_uv);
    float2 frac_part = frac(scaled_uv);
    int2 base_cell = int2((int)cell_floor.x, (int)cell_floor.y);

    float z_floor = floor(motion);
    float z_frac = frac(motion);
    int z0 = (int)z_floor % NMSG_TEX_Z_LOOP;
    int z1 = (z0 + 1) % NMSG_TEX_Z_LOOP;

    float c000 = nmsg_texture_fast_hash(int3(base_cell.x + 0, base_cell.y + 0, z0), salt);
    float c100 = nmsg_texture_fast_hash(int3(base_cell.x + 1, base_cell.y + 0, z0), salt);
    float c010 = nmsg_texture_fast_hash(int3(base_cell.x + 0, base_cell.y + 1, z0), salt);
    float c110 = nmsg_texture_fast_hash(int3(base_cell.x + 1, base_cell.y + 1, z0), salt);
    float c001 = nmsg_texture_fast_hash(int3(base_cell.x + 0, base_cell.y + 0, z1), salt);
    float c101 = nmsg_texture_fast_hash(int3(base_cell.x + 1, base_cell.y + 0, z1), salt);
    float c011 = nmsg_texture_fast_hash(int3(base_cell.x + 0, base_cell.y + 1, z1), salt);
    float c111 = nmsg_texture_fast_hash(int3(base_cell.x + 1, base_cell.y + 1, z1), salt);

    float tx = nmsg_texture_fade(frac_part.x);
    float ty = nmsg_texture_fade(frac_part.y);
    float tz = nmsg_texture_fade(z_frac);

    float x00 = lerp(c000, c100, tx);
    float x10 = lerp(c010, c110, tx);
    float x01 = lerp(c001, c101, tx);
    float x11 = lerp(c011, c111, tx);

    float y0 = lerp(x00, x10, ty);
    float y1 = lerp(x01, x11, ty);

    return lerp(y0, y1, tz);
}

float nmsg_texture_height_paper(float2 uv, float2 base_freq, float motion)
{
    float2 freq = max(base_freq, float2(1.0, 1.0));
    float amplitude = 0.5;
    float accum = 0.0;
    float total = 0.0;

    for (uint octave = 0u; octave < 3u; octave = octave + 1u)
    {
        uint salt = 0x9e3779b9u * (octave + 1u);
        float sample_val = nmsg_texture_value_noise(uv, freq, motion + (float)octave * 0.37, salt);
        float ridged = 1.0 - abs(sample_val * 2.0 - 1.0);
        accum = accum + ridged * amplitude;
        total = total + amplitude;
        freq = freq * 2.0;
        amplitude = amplitude * 0.55;
    }

    if (total <= 0.0) { return nmsg_texture_clamp01(accum); }
    return nmsg_texture_clamp01(accum / total);
}

float nmsg_texture_height_stucco(float2 uv, float2 base_freq, float motion)
{
    float2 freq = max(base_freq, float2(1.0, 1.0));
    float amplitude = 0.5;
    float accum = 0.0;
    float total = 0.0;

    for (uint octave = 0u; octave < 2u; octave = octave + 1u)
    {
        uint salt = 0x9e3779b9u * (octave + 1u);
        float sample_val = nmsg_texture_value_noise(uv, freq, motion + (float)octave * 0.37, salt);
        accum = accum + sample_val * amplitude;
        total = total + amplitude;
        freq = freq * 2.0;
        amplitude = amplitude * 0.5;
    }

    if (total <= 0.0) { return nmsg_texture_clamp01(accum); }
    return nmsg_texture_clamp01(accum / total);
}

float nmsg_texture_height_canvas(float2 uv, float2 base_freq, float motion)
{
    float2 st = uv * base_freq;
    float warpX = abs(sin(st.x * NMSG_TEX_PI));
    float weftY = abs(sin(st.y * NMSG_TEX_PI));
    float weave = warpX * weftY;

    float noise = nmsg_texture_value_noise(uv, base_freq * 0.5, motion, 0x12345678u);
    return nmsg_texture_clamp01(weave * 0.85 + noise * 0.15);
}

float nmsg_texture_height_halftone(float2 uv, float2 base_freq)
{
    float2 st = uv * base_freq;
    float2 cell = frac(st) - 0.5;
    float dotv = 1.0 - nmsg_texture_clamp01(length(cell) * 3.0);
    return dotv * dotv;
}

float nmsg_texture_height_crosshatch(float2 uv, float2 base_freq)
{
    float2 st = uv * base_freq;
    float d1 = abs(sin((st.x + st.y) * NMSG_TEX_PI));
    float d2 = abs(sin((st.x - st.y) * NMSG_TEX_PI));
    return nmsg_texture_clamp01(d1 * d2);
}

float nmsg_texture_height_field(int mode, float2 uv, float2 base_freq, float motion)
{
    [branch] if (mode == 0) { return nmsg_texture_height_canvas(uv, base_freq, motion); }
    [branch] if (mode == 1) { return nmsg_texture_height_crosshatch(uv, base_freq); }
    [branch] if (mode == 2) { return nmsg_texture_height_halftone(uv, base_freq); }
    [branch] if (mode == 4) { return nmsg_texture_height_stucco(uv, base_freq, motion); }
    return nmsg_texture_height_paper(uv, base_freq, motion);  // 3 = paper (default)
}

// Shader Graph Custom Function entry. Samples InputTex at UV (the fullscreen
// 0..1 UV), derives `dims` from the bound texture (WGSL `textureDimensions`),
// then applies the texture shading. `Time` is the engine-provided normalized
// animation time. `Mode` is the int dispatch (passed as float -> int).
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state so it matches
// the runtime's bilinear/clamp/linear path (H7).
void NM_Texture_float(
    UnityTexture2D InputTex,
    UnitySamplerState SS,
    float2         UV,
    float          Mode,
    float          Alpha,
    float          Scale,
    float          Time,
    out float4     Out)
{
    int mode = (int)Mode;

    float4 base_color = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);

    float texW, texH;
    InputTex.GetDimensions(texW, texH);
    float2 dims = float2(texW, texH);
    float2 pixel_step = 1.0 / dims;

    float a = clamp(Alpha, 0.0, 1.0);
    if (a <= 0.0)
    {
        Out = base_color;
        return;
    }

    float freq_scale = 24.0;
    [branch] if (mode == 4) { freq_scale = 48.0; }
    float2 base_freq = nmsg_texture_freq_for_shape(freq_scale * (10.01 - Scale), dims);
    float motion = Time * (float)NMSG_TEX_Z_LOOP;

    float h_center = nmsg_texture_height_field(mode, UV, base_freq, motion);
    float h_right  = nmsg_texture_height_field(mode, UV + float2(pixel_step.x, 0.0), base_freq, motion);
    float h_left   = nmsg_texture_height_field(mode, UV - float2(pixel_step.x, 0.0), base_freq, motion);
    float h_up     = nmsg_texture_height_field(mode, UV + float2(0.0, pixel_step.y), base_freq, motion);
    float h_down   = nmsg_texture_height_field(mode, UV - float2(0.0, pixel_step.y), base_freq, motion);

    float gx = h_right - h_left;
    float gy = h_down - h_up;
    float gradient = sqrt(gx * gx + gy * gy);

    float gain = NMSG_TEX_SHADE_GAIN * 0.25;
    [branch] if (mode == 4) { gain = NMSG_TEX_SHADE_GAIN * 0.5; }
    float shade_base = nmsg_texture_clamp01(gradient * gain);

    float highlight_mix = nmsg_texture_clamp01((shade_base * shade_base) * 1.25);
    float base_factor = 0.9 + h_center * 0.35;
    float factor = clamp(base_factor + highlight_mix * 0.35, 0.85, 1.6);

    float3 scaled_rgb = clamp(base_color.xyz * factor, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0));

    Out = float4(lerp(base_color.xyz, scaled_rgb, a), base_color.w);
}

#endif // NM_SG_TEXTURE_INCLUDED
