#ifndef NM_SPOOKYTICKER_SG_INCLUDED
#define NM_SPOOKYTICKER_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/SpookyTicker.hlsl
//
// Shader Graph Custom Function wrapper for filter/spookyTicker.
// Add a Custom Function node, point it at this file, select NM_SpookyTicker_float,
// and wire the InputTex/SS/UV/Time/Speed/Alpha/Rows/Seed inputs. Outputs RGBA.
//
// NOTE: spookyTicker reads `time` from the engine global provided by
// NMFullscreen.hlsl. In Shader Graph, wire the engine Time node into the Time
// input so the scroll animation is driven correctly.
//
// The core effect uses static const int GLYPHS[] and integer arithmetic — no
// per-pass state; single-pass Shader Graph use is valid.
// =============================================================================

#include "../../Shaders/Effects/filter/SpookyTicker.hlsl"

// InputTex : source surface (sampled at UV)
// SS       : sampler state (bilinear, clamp, linear/non-sRGB)
// UV       : 0..1 fragment UV (top-left origin, WGSL convention)
// Time     : current animation time (wire from engine Time node, normalized 0..1)
// Speed    : scroll speed multiplier (default 1.0)
// Alpha    : overlay opacity (default 0.75)
// Rows     : number of ticker rows from bottom (default 2)
// Seed     : hash seed for digit sequence (default 1)
void NM_SpookyTicker_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float             Time,
    float             Speed,
    float             Alpha,
    int               Rows,
    int               Seed,
    out float4        Out)
{
    // Override per-effect uniforms from node inputs.
    // The SpookyTicker.hlsl globals (speed, alpha, rows, seed, time) are
    // declared as module-scope uniforms; in Shader Graph context they are
    // overridden here via local variable shadowing is not reliable, so we
    // replicate the core logic inline to accept explicit parameters.
    // TODO(verify): confirm uniform shadowing behaviour in SG custom function context.

    float2 dims;
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    dims = float2((float)tw, (float)th);

    float2 fragCoord = UV * dims;
    float2 uv2       = UV;

    float4 src = InputTex.Sample(SS, uv2);

    float t = Time * Speed;
    uint baseSeed2 = hash_mix((uint)Seed * 7919u);

    static const int CELL_H2  = 24;
    static const int CELL_W2  = 21;
    static const int ROW_GAP2 = 4;

    int totalH = Rows * (CELL_H2 + ROW_GAP2);

    int px2           = (int)floor(uv2.x * dims.x);
    int pyFromBottom2 = (int)floor((1.0 - uv2.y) * dims.y);

    if (pyFromBottom2 >= totalH)
    {
        Out = src;
        return;
    }

    int rowStride2 = CELL_H2 + ROW_GAP2;
    int rowIdx2    = pyFromBottom2 / rowStride2;
    int localY2    = pyFromBottom2 - rowIdx2 * rowStride2;

    if (rowIdx2 >= Rows || localY2 >= CELL_H2)
    {
        Out = src;
        return;
    }

    int rowSeed2 = (int)hash_mix((uint)rowIdx2 + baseSeed2);

    float mask2   = ticker_row_mask(px2,     localY2,     rowSeed2, t);
    float shadow2 = 0.0;
    int shadowLocalY2 = localY2 + 2;
    if (shadowLocalY2 < CELL_H2)
    {
        shadow2 = ticker_row_mask(px2 + 2, shadowLocalY2, rowSeed2, t);
    }

    float3 result2 = src.rgb;
    result2 = result2 * (1.0 - shadow2 * 0.4 * Alpha);
    result2 = max(result2, float3(mask2, mask2, mask2) * Alpha);

    Out = float4(clamp(result2, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), src.a);
}

#endif // NM_SPOOKYTICKER_SG_INCLUDED
