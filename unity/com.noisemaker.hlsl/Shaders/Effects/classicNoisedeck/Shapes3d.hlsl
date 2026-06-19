#ifndef NM_SHAPES3D_INCLUDED
#define NM_SHAPES3D_INCLUDED

// =============================================================================
// Shapes3d.hlsl — classicNoisedeck/shapes3d, ported PIXEL-IDENTICALLY from
// the canonical WGSL source:
//   shaders/effects/classicNoisedeck/shapes3d/wgsl/shapes3d.wgsl
//
// Raymarched 3D geometric primitives with Phong-style lighting, orbit controls,
// SDF blending modes, optional repetition/flythrough, and palette coloring.
// Single render pass (definition.js passes[0].program "shapes3d").
//
// KIND: filter — samples inputTex for triplanar texture projection (weight>0).
//   Pass input: inputTex (definition.js passes[0].inputs.inputTex = "tex").
//
// PORTING-GUIDE notes:
//  * SHAPE_A, SHAPE_B, BLEND_MODE were compile-time defines in WGSL/GLSL; here
//    they are int uniforms + [branch] per PORTING-GUIDE §"Compile-time defines".
//  * modulo() is this effect's own helper (a-b*floor(a/b)); kept inline — NOT
//    nm_mod aliased — to mirror source 1:1. (Math is identical but name scoping
//    is per-effect per golden rule 2.)
//  * hsv2rgb, linearToSrgb, linear_srgb_from_oklab, luminance, pal,
//    rotate2D, smin/ssub/smax, shape3dA/B, blend, applyTransform, getDist,
//    getNormal, rayMarch — ALL this effect's own copies, verbatim.
//  * WGSL matrix layout: mat3x3<f32>(col0,col1,col2). In HLSL float3x3(r0,r1,r2)
//    rows are rows. The WGSL fwdA/fwdB/invA/invB constants are declared as
//    column vectors; we declare them as the same 3x3 values with mul() applied
//    in the same column-major sense: m*v in WGSL = mul(v,transpose(m)) in HLSL,
//    but it is cleaner to declare the transpose and use mul(m,v) in row-major.
//    See fwdA/fwdB below — transposed from the WGSL column declarations so that
//    mul(fwdA, lms) in HLSL matches fwdA * lms in WGSL. // TODO(verify)
//  * st = ((pos.xy + tileOffset) - 0.5*fullResolution) / fullResolution.y
//    follows the WGSL exactly (H13 divide-by-y).
//  * inputTex is sampled using applyTransform(p)*0.5+0.5 coords as in WGSL —
//    triplanar projection with normalized full-range coords, NOT the input tex
//    dimensions. The WGSL does NOT divide by textureDimensions here.
//  * repetition uniform is float, tested > 0.5 as WGSL does.
//  * nm_mod / fmod note: WGSL modulo() = a-b*floor(a/b) is replicated locally
//    as shapes3d_modulo(). All other uses are the WGSL operators directly.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Input texture + sampler (reference binding: inputTex@5) -----------------
Texture2D    inputTex;
SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (definition.js globals[*].uniform) ------------
// Compile-time defines (SHAPE_A, SHAPE_B, BLEND_MODE) mapped to int uniforms.
int   SHAPE_A;             // default 30 (torusVert)
int   SHAPE_B;             // default 10 (cube)
int   BLEND_MODE;          // default 10 (smoothUnion)

float shapeAScale;         // default 64
float shapeBScale;         // default 27
float shapeAThickness;     // default 5
float shapeBThickness;     // default 5
float smoothness;          // default 1
float repetition;          // boolean, default 0 (false); test > 0.5
float animation;           // int 0|1, default 1
float flythroughSpeed;     // default 0
float spacing;             // int, default 10
float spin;                // default 0
float spinSpeed;           // default 2
float flip;                // default 0
float flipSpeed;           // default 2
float cameraDist;          // default 8
float3 bgColor;            // default (1,1,1)
float bgAlpha;             // default 0
float weight;              // default 0
float colorMode;           // int 0|1|10, default 10
float3 paletteOffset;      // default (0.83,0.6,0.63)
float3 paletteAmp;         // default (0.5,0.5,0.5)
float3 paletteFreq;        // default (1,1,1)
float3 palettePhase;       // default (0.3,0.1,0)
float cyclePalette;        // int -1|0|1, default 1
float rotatePalette;       // default 0
float repeatPalette;       // default 1
float paletteMode;         // int 0|1|2, default 0

// ---- Constants ---------------------------------------------------------------
static const float SHAPES3D_PI  = 3.14159265359;
static const float SHAPES3D_TAU = 6.28318530718;

// ---- Per-effect helpers (verbatim from WGSL) ---------------------------------

float shapes3d_modulo(float a, float b)
{
    return a - b * floor(a / b);
}

float3 shapes3d_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;
    float c = v * s;
    float x = c * (1.0 - abs(shapes3d_modulo(h * 6.0, 2.0) - 1.0));
    float m = v - c;
    float3 rgb = float3(0.0, 0.0, 0.0);
    if (0.0 <= h && h < 1.0/6.0) {
        rgb = float3(c, x, 0.0);
    } else if (1.0/6.0 <= h && h < 2.0/6.0) {
        rgb = float3(x, c, 0.0);
    } else if (2.0/6.0 <= h && h < 3.0/6.0) {
        rgb = float3(0.0, c, x);
    } else if (3.0/6.0 <= h && h < 4.0/6.0) {
        rgb = float3(0.0, x, c);
    } else if (4.0/6.0 <= h && h < 5.0/6.0) {
        rgb = float3(x, 0.0, c);
    } else if (5.0/6.0 <= h && h < 1.0) {
        rgb = float3(c, 0.0, x);
    }
    return rgb + float3(m, m, m);
}

float3 shapes3d_linearToSrgb(float3 linear)
{
    float3 srgb = float3(0.0, 0.0, 0.0);
    // component 0
    if (linear.r <= 0.0031308) { srgb.r = linear.r * 12.92; }
    else                        { srgb.r = 1.055 * pow(linear.r, 1.0 / 2.4) - 0.055; }
    // component 1
    if (linear.g <= 0.0031308) { srgb.g = linear.g * 12.92; }
    else                        { srgb.g = 1.055 * pow(linear.g, 1.0 / 2.4) - 0.055; }
    // component 2
    if (linear.b <= 0.0031308) { srgb.b = linear.b * 12.92; }
    else                        { srgb.b = 1.055 * pow(linear.b, 1.0 / 2.4) - 0.055; }
    return srgb;
}

// WGSL fwdA is declared as mat3x3<f32>(col0, col1, col2).
// Transposed to row-major for mul(fwdA_rm, v) == fwdA * v in WGSL.
// fwdA columns: c0=(1,1,1), c1=(0.3963377774,-0.1055613458,-0.0894841775),
//               c2=(0.2158037573,-0.0638541728,-1.2914855480)
// Row-major rows: r0=(1,0.3963377774,0.2158037573), r1=(1,-0.1055613458,-0.0638541728),
//                 r2=(1,-0.0894841775,-1.2914855480)
static const float3x3 shapes3d_fwdA = float3x3(
    1.0,  0.3963377774,  0.2158037573,
    1.0, -0.1055613458, -0.0638541728,
    1.0, -0.0894841775, -1.2914855480
);

// fwdB columns: c0=(4.0767245293,-1.2681437731,-0.0041119885),
//               c1=(-3.3072168827,2.6093323231,-0.7034763098),
//               c2=(0.2307590544,-0.3411344290,1.7068625689)
static const float3x3 shapes3d_fwdB = float3x3(
     4.0767245293, -3.3072168827,  0.2307590544,
    -1.2681437731,  2.6093323231, -0.3411344290,
    -0.0041119885, -0.7034763098,  1.7068625689
);

float3 shapes3d_linear_srgb_from_oklab(float3 c)
{
    float3 lms = mul(shapes3d_fwdA, c);
    return mul(shapes3d_fwdB, lms * lms * lms);
}

float shapes3d_luminance(float3 color)
{
    return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

float3 shapes3d_pal(float t0,
                    float3 pOffset, float3 pAmp, float3 pFreq, float3 pPhase,
                    int pMode, float repPal, float rotPal)
{
    float t = abs(t0);
    t = t * repPal + rotPal * 0.01;
    float3 color = pOffset + pAmp * cos(SHAPES3D_TAU * (pFreq * t + pPhase));
    if (pMode == 1) {
        color = shapes3d_hsv2rgb(color);
    } else if (pMode == 2) {
        color.g = color.g * -0.509 + 0.276;
        color.b = color.b * -0.509 + 0.198;
        color = shapes3d_linear_srgb_from_oklab(color);
        color = shapes3d_linearToSrgb(color);
    }
    return color;
}

float2 shapes3d_rotate2D(float2 st, float rot)
{
    float angle = rot * SHAPES3D_PI;
    float s = sin(angle);
    float c = cos(angle);
    // WGSL: mat2x2<f32>(c, -s, s, c) * st  (column-major, so col0=(c,s), col1=(-s,c))
    // => result.x = c*st.x + (-s)*st.y, result.y = s*st.x + c*st.y
    return float2(c * st.x - s * st.y, s * st.x + c * st.y);
}

float shapes3d_smin(float a, float b, float k)
{
    float h = clamp(0.5 + 0.5*(b - a)/k, 0.0, 1.0);
    return lerp(b, a, h) - k*h*(1.0 - h);
}

float shapes3d_ssub(float a, float b, float k)
{
    float h = clamp(0.5 - 0.5*(b + a)/k, 0.0, 1.0);
    return lerp(b, -a, h) + k*h*(1.0 - h);
}

float shapes3d_smax(float a, float b, float k)
{
    float h = clamp(0.5 - 0.5*(b - a)/k, 0.0, 1.0);
    return lerp(b, a, h) + k*h*(1.0 - h);
}

float shapes3d_shape3dA(float3 p, float3 origin, float scale, float thickness)
{
    float d = 0.0;
    float s = scale * 0.25;
    float3 q = p;
    [branch]
    if (SHAPE_A == 20) {
        d = length(p - origin) - s;
    } else if (SHAPE_A == 30) {
        q = float3(length(p.xy) - s, p.z, 0.0);
        d = length(q.xy) - 0.2;
    } else if (SHAPE_A == 31) {
        q = float3(length(p.xz) - s, p.y, 0.0);
        d = length(q.xy) - 0.2;
    } else if (SHAPE_A == 10) {
        s = s * 0.75;
        q = p - clamp(p, float3(-s,-s,-s), float3(s,s,s));
        d = length(q) - 0.01;
    } else if (SHAPE_A == 40) {
        s = s * 0.75;
        d = length(p.xz) - s;
    } else if (SHAPE_A == 50) {
        s = s * 0.75;
        d = max(length(p - clamp(p, float3(-s,-s,-s), float3(s,s,s))), length(p.xy) - s);
    } else if (SHAPE_A == 60) {
        q = p;
        q.y = q.y - clamp(q.y, -scale * 0.5, scale * 0.5);
        d = length(q) - s * 0.5;
    } else if (SHAPE_A == 70) {
        q = p;
        q.x = q.x - clamp(q.x, -scale * 0.5, scale * 0.5);
        d = length(q) - s * 0.5;
    } else if (SHAPE_A == 80) {
        q = abs(p);
        return (q.x + q.y + q.z - s) * 0.57735027;
    }
    d = abs(d) - (thickness * 0.01);
    return d;
}

float shapes3d_shape3dB(float3 p, float3 origin, float scale, float thickness)
{
    float d = 0.0;
    float s = scale * 0.25;
    float3 q = p;
    [branch]
    if (SHAPE_B == 20) {
        d = length(p - origin) - s;
    } else if (SHAPE_B == 30) {
        q = float3(length(p.xy) - s, p.z, 0.0);
        d = length(q.xy) - 0.2;
    } else if (SHAPE_B == 31) {
        q = float3(length(p.xz) - s, p.y, 0.0);
        d = length(q.xy) - 0.2;
    } else if (SHAPE_B == 10) {
        s = s * 0.75;
        q = p - clamp(p, float3(-s,-s,-s), float3(s,s,s));
        d = length(q) - 0.01;
    } else if (SHAPE_B == 40) {
        s = s * 0.75;
        d = length(p.xz) - s;
    } else if (SHAPE_B == 50) {
        s = s * 0.75;
        d = max(length(p - clamp(p, float3(-s,-s,-s), float3(s,s,s))), length(p.xy) - s);
    } else if (SHAPE_B == 60) {
        q = p;
        q.y = q.y - clamp(q.y, -scale * 0.5, scale * 0.5);
        d = length(q) - s * 0.5;
    } else if (SHAPE_B == 70) {
        q = p;
        q.x = q.x - clamp(q.x, -scale * 0.5, scale * 0.5);
        d = length(q) - s * 0.5;
    } else if (SHAPE_B == 80) {
        q = abs(p);
        return (q.x + q.y + q.z - s) * 0.57735027;
    }
    d = abs(d) - (thickness * 0.01);
    return d;
}

float shapes3d_blend(float shape1, float shape2, float sm)
{
    float d = 0.0;
    [branch]
    if (BLEND_MODE == 10) {
        d = shapes3d_smin(shape1, shape2, sm * 0.02);
    } else if (BLEND_MODE == 20) {
        d = shapes3d_smax(shape1, shape2, sm * 0.01);
    } else if (BLEND_MODE == 25) {
        d = shapes3d_ssub(shape1, shape2, sm * 0.02);
    } else if (BLEND_MODE == 26) {
        d = shapes3d_ssub(-shape1, shape2, sm * 0.02);
    } else if (BLEND_MODE == 30) {
        d = min(shape1, shape2);
    } else if (BLEND_MODE == 40) {
        d = max(shape1, shape2);
    } else if (BLEND_MODE == 50) {
        d = max(-shape1, shape2);
    } else if (BLEND_MODE == 51) {
        d = max(shape1, -shape2);
    } else {
        d = shape1;
    }
    return d;
}

float3 shapes3d_applyTransform(float3 p0)
{
    float3 p = p0;
    if (repetition > 0.5 && (int)round(animation) != 0 && flythroughSpeed != 0.0) {
        p.z = p.z + time * flythroughSpeed;
    }
    float2 rotXZ = shapes3d_rotate2D(p.xz, spin / 180.0);
    p.x = rotXZ.x;
    p.z = rotXZ.y;
    float2 rotYZ = shapes3d_rotate2D(p.yz, flip / 180.0);
    p.y = rotYZ.x;
    p.z = rotYZ.y;
    if (repetition > 0.5 && (int)round(animation) == 1) {
        p = p - spacing * round(p / spacing);
    }
    rotXZ = shapes3d_rotate2D(p.xz, time * (spinSpeed * 0.1));
    p.x = rotXZ.x;
    p.z = rotXZ.y;
    rotYZ = shapes3d_rotate2D(p.yz, time * (flipSpeed * 0.1));
    p.y = rotYZ.x;
    p.z = rotYZ.y;
    if (repetition > 0.5 && (int)round(animation) == 0) {
        p = p - spacing * round(p / spacing);
    }
    return p;
}

float shapes3d_getDist(float3 p0)
{
    float3 p = shapes3d_applyTransform(p0);
    float shape1 = shapes3d_shape3dA(p, float3(0.0, 0.0, 0.0), 1.0 + shapeAScale * 0.1, shapeAThickness);
    float shape2 = shapes3d_shape3dB(p, float3(0.0, 0.0, 0.0), 1.0 + shapeBScale * 0.1, shapeBThickness);
    return shapes3d_blend(shape1, shape2, smoothness);
}

float3 shapes3d_getNormal(float3 p)
{
    float epsilon = 0.01;
    float d  = shapes3d_getDist(p);
    float dx = shapes3d_getDist(p + float3(epsilon, 0.0, 0.0)) - d;
    float dy = shapes3d_getDist(p + float3(0.0, epsilon, 0.0)) - d;
    float dz = shapes3d_getDist(p + float3(0.0, 0.0, epsilon)) - d;
    return normalize(float3(dx, dy, dz));
}

float shapes3d_rayMarch(float3 rayOrigin, float3 rayDirection)
{
    float d = 0.0;
    int maxSteps = 100;
    float maxDist = 200.0;
    float minDist = 0.01;
    for (int i = 0; i < maxSteps; i = i + 1) {
        float3 p = rayOrigin + rayDirection * d;
        float dist = shapes3d_getDist(p);
        d = d + dist;
        if (d > maxDist || dist < minDist) {
            break;
        }
    }
    return d;
}

// ---- Pass: "shapes3d" (progName "shapes3d") ----------------------------------
float4 NMFrag_shapes3d(NMVaryings i) : SV_Target
{
    // WGSL: pos = @builtin(position)
    // st = ((pos.xy + tileOffset) - 0.5 * fullResolution) / fullResolution.y
    float2 pos = NM_FragCoord(i);
    float2 st = ((pos + tileOffset) - 0.5 * fullResolution) / fullResolution.y;

    float3 rayOrigin = float3(0.0, 0.0, -cameraDist);
    float3 rayDirection = normalize(float3(st, 1.0));
    float d = shapes3d_rayMarch(rayOrigin, rayDirection);

    float3 p = rayOrigin + rayDirection * d;
    float3 lightPosition = float3(-5.0, 5.0, -5.0);
    float3 lightVector = normalize(lightPosition - p);
    float3 normal = shapes3d_getNormal(p);
    float diffuse = clamp(dot(normal, lightVector), 0.0, 1.0);

    float4 color = float4(1.0, 1.0, 1.0, 1.0);

    if (weight > 0.0) {
        float3 tp = shapes3d_applyTransform(p);
        tp = tp * 0.5 + float3(0.5, 0.5, 0.5);
        float3 colorXY = float3(0.0, 0.0, 0.0);
        float3 colorXZ = float3(0.0, 0.0, 0.0);
        float3 colorYZ = float3(0.0, 0.0, 0.0);
        colorXY = inputTex.Sample(sampler_inputTex, tp.xy).rgb;
        colorXZ = inputTex.Sample(sampler_inputTex, tp.xz).rgb;
        colorYZ = inputTex.Sample(sampler_inputTex, tp.yz).rgb;
        float3 absNormal = abs(normal);
        color = float4(colorXY * absNormal.z + colorXZ * absNormal.y + colorYZ * absNormal.x, color.a);
    }

    int iColorMode = (int)round(colorMode);
    [branch]
    if (iColorMode == 0) {
        color = float4(color.rgb * float3(1.0 - clamp(d * 0.035, 0.0, 1.0), 1.0 - clamp(d * 0.035, 0.0, 1.0), 1.0 - clamp(d * 0.035, 0.0, 1.0)), color.a);
    } else if (iColorMode == 1) {
        color = float4(color.rgb * (float3(diffuse * 1.5, diffuse * 1.5, diffuse * 1.5) + float3(0.5, 0.5, 0.5)), color.a);
    } else if (iColorMode == 10) {
        color = float4(color.rgb * (float3(diffuse * 1.5, diffuse * 1.5, diffuse * 1.5) + float3(0.5, 0.5, 0.5)), color.a);
        float lum = shapes3d_luminance(color.rgb);
        int iCycle = (int)round(cyclePalette);
        if (iCycle == -1) {
            lum = lum + time;
        } else if (iCycle == 1) {
            lum = lum - time;
        }
        int iPalMode = (int)round(paletteMode);
        color = float4(color.rgb * shapes3d_pal(lum, paletteOffset, paletteAmp, paletteFreq, palettePhase,
                                                 iPalMode, repeatPalette, rotatePalette), color.a);
    }

    float fogDist = clamp(d / 200.0, 0.0, 1.0);
    float4 bkg = float4(bgColor, bgAlpha * 0.01);
    if (repetition > 0.5) {
        color = lerp(color, bkg, fogDist);
    } else {
        color = lerp(color, bkg, floor(fogDist));
    }

    return color;
}

#endif // NM_SHAPES3D_INCLUDED
