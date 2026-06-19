#ifndef NM_PRISMATIC_ABERRATION_INCLUDED
#define NM_PRISMATIC_ABERRATION_INCLUDED

// =============================================================================
// PrismaticAberration.hlsl — filter/prismaticAberration, ported PIXEL-IDENTICALLY
// from the canonical WGSL:
//   shaders/effects/filter/prismaticAberration/wgsl/prismaticAberration.wgsl
//
// Single render pass ("prismaticAberration"). Samples inputTex three times with
// horizontal offsets proportional to center distance for chromatic fringing, then
// boosts the edge signal through HSV and recombines with a desaturated passthrough.
//
// PORTING NOTES:
//  * floorMod (WGSL) == nm_mod from NMCore (floored modulo).
//  * mapVal (WGSL) == nm_map from NMCore.
//  * hsv2rgb / rgb2hsv / saturateColor are THIS EFFECT'S copies — ported verbatim.
//  * The WGSL's HSV uses the % operator on a float (h * 6.0) % 2.0 which is
//    WGSL's floored modulo for positive values. Here that is nm_mod(h*6.0, 2.0).
//  * uv = (fragCoord + tileOffset) / fullResolution => NM_GlobalCoord(i) / fullResolution
//  * texSize = textureDimensions(inputTex) => GetDimensions().
//  * Sample coords: (vec2f(...) * fullResolution - tileOffset) / texSize (verbatim).
//  * modulate: declared int; WGSL tests `u.modulate != 0`.
//  * Full 32-bit float. No fmod — use nm_mod.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
float  aberrationAmt;   // globals.aberration.uniform "aberrationAmt",  default 50
int    modulate;        // globals.modulate.uniform   "modulate",        default 0 (false)
float  hueRotation;     // globals.hueRotation.uniform "hueRotation",    default 0
float  hueRange;        // globals.hueRange.uniform   "hueRange",        default 0
float  saturation;      // globals.saturation.uniform "saturation",      default 0
float  passthru;        // globals.passthru.uniform   "passthru",        default 50

// -----------------------------------------------------------------------------
// hsv2rgb — ported VERBATIM from prismaticAberration.wgsl.
// WGSL uses (h * 6.0) % 2.0 which is floored mod => nm_mod(h*6.0, 2.0).
// -----------------------------------------------------------------------------
float3 nm_pa_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(nm_mod(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb;
    [branch]
    if (h < 1.0 / 6.0) {
        rgb = float3(c, x, 0.0);
    } else if (h < 2.0 / 6.0) {
        rgb = float3(x, c, 0.0);
    } else if (h < 3.0 / 6.0) {
        rgb = float3(0.0, c, x);
    } else if (h < 4.0 / 6.0) {
        rgb = float3(0.0, x, c);
    } else if (h < 5.0 / 6.0) {
        rgb = float3(x, 0.0, c);
    } else {
        rgb = float3(c, 0.0, x);
    }

    return rgb + float3(m, m, m);
}

// -----------------------------------------------------------------------------
// rgb2hsv — ported VERBATIM from prismaticAberration.wgsl.
// WGSL: floorMod((g-b)/delta, 6.0) => nm_mod((g-b)/delta, 6.0)
// -----------------------------------------------------------------------------
float3 nm_pa_rgb2hsv(float3 rgb)
{
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    float maxC = max(r, max(g, b));
    float minC = min(r, min(g, b));
    float delta = maxC - minC;

    float h = 0.0;
    if (delta != 0.0) {
        if (maxC == r) {
            h = nm_mod((g - b) / delta, 6.0) / 6.0;
        } else if (maxC == g) {
            h = ((b - r) / delta + 2.0) / 6.0;
        } else {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
    }
    if (h < 0.0) { h = h + 1.0; }

    float s = 0.0;
    if (maxC != 0.0) {
        s = delta / maxC;
    }
    float v = maxC;

    return float3(h, s, v);
}

// -----------------------------------------------------------------------------
// saturateColor — ported VERBATIM from prismaticAberration.wgsl.
// Uses nm_map (== WGSL mapVal).
// -----------------------------------------------------------------------------
float3 nm_pa_saturateColor(float3 col)
{
    float sat = nm_map(saturation, -100.0, 100.0, -1.0, 1.0);
    float avg = (col.r + col.g + col.b) / 3.0;
    return col - (avg - col) * sat;
}

// -----------------------------------------------------------------------------
// nm_prismaticAberration — core per-pixel evaluation.
// Ported VERBATIM from prismaticAberration.wgsl main().
// Takes already-computed uv, texSize, texSamples for portability.
// -----------------------------------------------------------------------------
float4 nm_prismaticAberration(
    Texture2D    inputTex,
    SamplerState samp,
    float2       fragCoord)   // NM_FragCoord(i) — pixel-centered, top-left
{
    float2 uv = (fragCoord + tileOffset) / fullResolution;

    uint tw, th;
    inputTex.GetDimensions(tw, th);
    float2 texSize = float2(tw, th);

    float4 color = float4(0.0, 0.0, 0.0, 1.0);

    float2 diff = float2(0.5 * aspectRatio, 0.5) - float2(uv.x * aspectRatio, uv.y);
    float  centerDist = length(diff);

    // No distortion/zoom
    float2 lensedCoords = uv;

    float aberrationOffset = nm_map(aberrationAmt, 0.0, 100.0, 0.0, 0.05) * centerDist * NM_PI * 0.5;

    float  redOffset = lerp(clamp(lensedCoords.x + aberrationOffset, 0.0, 1.0), lensedCoords.x, lensedCoords.x);
    float4 red = inputTex.Sample(samp, (float2(redOffset, lensedCoords.y) * fullResolution - tileOffset) / texSize);

    float4 green = inputTex.Sample(samp, (lensedCoords * fullResolution - tileOffset) / texSize);

    float  blueOffset = lerp(lensedCoords.x, clamp(lensedCoords.x - aberrationOffset, 0.0, 1.0), lensedCoords.x);
    float4 blue = inputTex.Sample(samp, (float2(blueOffset, lensedCoords.y) * fullResolution - tileOffset) / texSize);

    // from aberration
    float3 hsv = float3(1.0, 1.0, 1.0);

    float t = 0.0;
    if (modulate != 0) {
        t = time;
    }

    // prismatic - get edges
    // WGSL: color = vec4f(vec3f(length(vec4f(red.r, green.g, blue.b, color.a) - green)) * green.rgb, green.a)
    float edgeLen = length(float4(red.r, green.g, blue.b, color.a) - green);
    color = float4(float3(edgeLen, edgeLen, edgeLen) * green.rgb, green.a);

    // boost hue range of edges
    hsv = nm_pa_rgb2hsv(color.rgb);
    hsv = float3(frac(((hsv.x + 0.125 + (1.0 - (hueRotation / 360.0))) * (2.0 + hueRange * 0.05)) + t), 1.0, hsv.z);

    // desaturate original
    float3 greenMod = nm_pa_saturateColor(green.rgb) * nm_map(passthru, 0.0, 100.0, 0.0, 2.0);

    // recombine (add)
    color = float4(min(greenMod + nm_pa_hsv2rgb(hsv), float3(1.0, 1.0, 1.0)), color.a);

    return color;
}

#endif // NM_PRISMATIC_ABERRATION_INCLUDED
