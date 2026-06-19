#ifndef NM_BITWISE_INCLUDED
#define NM_BITWISE_INCLUDED

// =============================================================================
// Bitwise.hlsl — synth/bitwise, ported PIXEL-IDENTICALLY from the canonical
// WGSL source:
//   shaders/effects/synth/bitwise/wgsl/bitwise.wgsl
//
// Bitwise operation patterns (XOR squares, AND, OR, etc.) with rotation,
// animation, and multiple color modes.
//
// Per PORTING-GUIDE: helpers (hsv2rgb, bitOp) are INLINE copies of THIS
// effect's own versions. No shared helper substitution.
//
// NUMERIC NOTES:
//  * Rotation applied in pixel space around fullResolution*0.5 center.
//  * animOffset uses int(floor(time * float(-speed) * 256.0)) — note WGSL
//    uses i32(-speed) then f32(...); HLSL (int)(-speed) is identical.
//  * Integer coords from floor(coord / pixelScale) — float->int truncation.
//  * Seed XOR: x ^= seed; y ^= (seed * 3).
//  * bitOp: mask applied with &, normalize by f32(r)/f32(m) — signed int / signed int.
//  * hueScale = float(mask) / float(mask + 1).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int    operation;    // 0=xor,1=and,2=or,3=nand,4=xnor,5=mul,6=add,7=sub
int    mask;         // bit mask: 255,127,63,31,15,7,3,1
float  scale;        // [1,100], default 50
float  rotation;     // degrees [-180,180], default 0
int    offsetX;      // [-256,256]
int    offsetY;      // [-256,256]
int    seed;         // [0,255]
int    speed;        // [-5,5]
int    colorMode;    // 0=mono,1=rgb,2=hsv
int    colorOffset;  // [0,64], default 7

// ---- PI -----------------------------------------------------------------------
static const float NMB_PI = 3.14159265358979;

// ---- hsv2rgb (verbatim from WGSL, branchless) --------------------------------
// WGSL:
//   let p = abs(fract(c.xxx + vec3<f32>(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
//   return c.z * mix(vec3<f32>(1.0), clamp(p - 1.0, vec3<f32>(0.0), vec3<f32>(1.0)), vec3<f32>(c.y));
float3 nmb_hsv2rgb(float3 c)
{
    float3 p = abs(frac(c.xxx + float3(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
    return c.z * lerp(float3(1.0, 1.0, 1.0), clamp(p - 1.0, float3(0.0, 0.0, 0.0), float3(1.0, 1.0, 1.0)), c.y);
}

// ---- bitOp: bitwise/arithmetic op, mask, normalize ---------------------------
// WGSL:
//   fn bitOp(a: i32, b: i32, op: i32, m: i32) -> f32 {
//       var r: i32 = 0;
//       if (op==0){r=a^b} else if(op==1){r=a&b} ... else {r=a-b}
//       r = r & m;
//       return f32(r) / f32(m);
//   }
float nmb_bitOp(int a, int b, int op, int m)
{
    int r = 0;
    [branch]
    if      (op == 0) { r = a ^ b;      }   // xor
    else if (op == 1) { r = a & b;      }   // and
    else if (op == 2) { r = a | b;      }   // or
    else if (op == 3) { r = ~(a & b);   }   // nand
    else if (op == 4) { r = ~(a ^ b);   }   // xnor
    else if (op == 5) { r = a * b;      }   // mul
    else if (op == 6) { r = a + b;      }   // add
    else              { r = a - b;      }   // sub
    r = r & m;
    return (float)r / (float)m;
}

// =============================================================================
// nm_bitwise — core per-pixel evaluation.
// `globalCoord` = NM_GlobalCoord(i), i.e. pixel coord + tileOffset (top-left).
// =============================================================================
float4 nm_bitwise(float2 globalCoord)
{
    // Map scale so higher value = bigger cells (lower frequency)
    float pixelScale = scale * 0.1 * renderScale;

    // Apply rotation around screen center (WGSL: around fullResolution * 0.5)
    // globalCoord = position.xy + tileOffset (already the WGSL `position.xy + tileOffset`).
    float angle = rotation * NMB_PI / 180.0;
    float ca = cos(angle);
    float sa = sin(angle);
    float2 centered = globalCoord - fullResolution * 0.5;
    float2 rotated = float2(centered.x * ca - centered.y * sa,
                            centered.x * sa + centered.y * ca);
    float2 coord = rotated + fullResolution * 0.5;

    // Time offset — 256 pattern period for seamless looping
    int animOffset = (int)floor(time * (float)(-speed) * 256.0);

    // Integer coordinates
    int x = (int)floor(coord.x / pixelScale) + offsetX + animOffset;
    int y = (int)floor(coord.y / pixelScale) + offsetY;

    // Seed XOR
    x = x ^ seed;
    y = y ^ (seed * 3);

    [branch]
    if (colorMode == 0)
    {
        // Mono: same operation across all channels
        float v = nmb_bitOp(x, y, operation, mask);
        return float4(v, v, v, 1.0);
    }
    else if (colorMode == 1)
    {
        // RGB: channel-shifted patterns (chromatic aberration)
        float r = nmb_bitOp(x, y, operation, mask);
        float g = nmb_bitOp(x + colorOffset, y, operation, mask);
        float b = nmb_bitOp(x, y + colorOffset, operation, mask);
        return float4(r, g, b, 1.0);
    }
    else
    {
        // HSV: bitwise value drives hue, full saturation and value
        float v = nmb_bitOp(x, y, operation, mask);
        float hueScale = (float)mask / (float)(mask + 1);
        return float4(nmb_hsv2rgb(float3(v * hueScale, 1.0, 1.0)), 1.0);
    }
}

#endif // NM_BITWISE_INCLUDED
