#ifndef NM_SG_SNOW_INCLUDED
#define NM_SG_SNOW_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/snow.
//
// void NM_Snow_float(InputTex, SS, UV, Alpha, Pause, Density, out Out)
//
// UV must be the input texture's own 0..1 UV. Internally the hash operates on
// integer pixel coords (floor(UV * texDims)) to match WGSL gid semantics.
// Pause is float: 0=animate, 1=freeze (compared > 0.5, per WGSL select).
// Time is injected via _Time.y (Unity built-in), 0..1-normalized to match the
// runtime's _NM_Time. TODO(verify): confirm time normalization matches runtime.
//
// Self-contained — does NOT include NMFullscreen.hlsl / NMCore.hlsl.
// Helpers prefixed `nmsg_snow_` to avoid symbol clashes.
// =============================================================================

static const float NMSG_SNOW_TAU               = 6.283185307179586;
static const float3 NMSG_SNOW_TIME_SEED_OFFSETS = float3(97.0, 57.0, 131.0);
static const float3 NMSG_SNOW_STATIC_SEED       = float3(37.0, 17.0, 53.0);
static const float3 NMSG_SNOW_LIMITER_SEED      = float3(113.0, 71.0, 193.0);

float nmsg_snow_normalized_sine(float value)
{
    return (sin(value) + 1.0) * 0.5;
}

float nmsg_snow_periodic_value(float t, float value)
{
    return nmsg_snow_normalized_sine((t - value) * NMSG_SNOW_TAU);
}

float3 nmsg_snow_fract_vec3(float3 value)
{
    return value - floor(value);
}

float nmsg_snow_hash(float3 sample_in)
{
    float3 scaled    = nmsg_snow_fract_vec3(sample_in * 0.1031);
    float  dot_val   = dot(scaled, scaled.yzx + float3(33.33, 33.33, 33.33));
    float3 shifted   = scaled + dot_val;
    float  combined  = (shifted.x + shifted.y) * shifted.z;
    float  fractional = combined - floor(combined);
    return clamp(fractional, 0.0, 1.0);
}

float nmsg_snow_noise(float2 coord, float t, float speed, float3 seed)
{
    float  angle      = t * NMSG_SNOW_TAU;
    float  z_base     = cos(angle) * speed;
    float3 base_sample = float3(coord.x + seed.x, coord.y + seed.y, z_base + seed.z);
    float  base_value  = nmsg_snow_hash(base_sample);

    [branch]
    if (speed == 0.0 || t == 0.0)
    {
        return base_value;
    }

    float3 time_seed   = seed + NMSG_SNOW_TIME_SEED_OFFSETS;
    float3 time_sample = float3(
        coord.x + time_seed.x,
        coord.y + time_seed.y,
        1.0 + time_seed.z
    );
    float time_value  = nmsg_snow_hash(time_sample);
    float scaled_time = nmsg_snow_periodic_value(t, time_value) * speed;
    float periodic    = nmsg_snow_periodic_value(scaled_time, base_value);
    return clamp(periodic, 0.0, 1.0);
}

// Shader Graph Custom Function entry.
// TODO(verify): _Time.y must be normalized to the same 0..1 range as _NM_Time;
// replace `_Time.y` below with the Time node output configured to match.
void NM_Snow_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Alpha,
    float             Pause,
    float             Density,
    out float4        Out)
{
    float texW, texH;
    InputTex.tex.GetDimensions(texW, texH);
    float2 dims  = float2(texW, texH);

    // Integer pixel coords matching WGSL gid semantics
    int2   icoord = (int2)floor(UV * dims);
    float4 texel  = LOAD_TEXTURE2D(InputTex.tex, icoord);

    float alphaVal = clamp(Alpha, 0.0, 1.0);

    if (alphaVal == 0.0)
    {
        Out = texel;
        return;
    }

    float2 coord = float2((float)icoord.x, (float)icoord.y);
    float  t     = (Pause > 0.5) ? 0.0 : _Time.y;  // TODO(verify): time normalization
    float  speed = 100.0;

    float static_value  = nmsg_snow_noise(coord, t, speed, NMSG_SNOW_STATIC_SEED);
    float limiter_value = nmsg_snow_noise(coord, t, speed, NMSG_SNOW_LIMITER_SEED);
    float d             = max(Density * 0.01, 0.0001);
    float exponent      = (1.0 - d) / d;
    float limiter_mask  = pow(min(limiter_value, 0.99), exponent) * alphaVal;

    float3 static_color = float3(static_value, static_value, static_value);
    float3 mixed_rgb    = lerp(texel.xyz, static_color, float3(limiter_mask, limiter_mask, limiter_mask));

    Out = float4(mixed_rgb, texel.w);
}

#endif // NM_SG_SNOW_INCLUDED
