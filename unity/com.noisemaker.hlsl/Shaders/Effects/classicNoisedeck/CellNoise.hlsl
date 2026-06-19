#ifndef NM_EFFECT_CELLNOISE_INCLUDED
#define NM_EFFECT_CELLNOISE_INCLUDED

// =============================================================================
// CellNoise.hlsl — classicNoisedeck/cellNoise (func: "cellNoise")
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL source:
//   shaders/effects/classicNoisedeck/cellNoise/wgsl/cellNoise.wgsl
//
// Worley/cellular noise generator with an OPTIONAL input surface `tex`
// (definition.js inputs: { tex: "tex" }; globals.tex type "surface"). The WGSL
// binds one texture `tex` + sampler `samp`; the HLSL sampler is therefore named
// `sampler_tex`. With the default texIntensity = 0 and no surface wired the
// texture path is inert and the effect behaves as a pure generator. Single pass.
//
// PORTING-GUIDE notes / hazards handled:
//  * st = (NM_GlobalCoord(i)) / fullResolution.y  -> DIVIDE BY HEIGHT (.y). WGSL
//    main(): st = (pos.xy + tileOffset) / fullResolution.y. (H13)
//  * texCoord = (pos.xy + tileOffset) / fullResolution (BOTH axes) — WGSL is
//    canonical. The GLSL instead samples at gl_FragCoord.xy / textureSize(tex,0);
//    we follow the WGSL literally. tileOffset IS included in the sample coord.
//  * Helpers (modulo, map, hsv2rgb, rgb2hsv, linearToSrgb, oklab fwd/inv, pal,
//    luminance, polarShape, shape, wrapEdges, smin, cells) are this effect's OWN
//    copies, ported VERBATIM inline. Only pcg/prng come from NMCore (nm_prng).
//    `map`/`modulo` duplicate NMCore math but are kept inline to mirror the WGSL.
//  * prng arg order copied LITERALLY:
//      prng(vec3<f32>(f32(seed)))            -> nm_prng(float3(seed,0,0))? NO —
//        WGSL vec3<f32>(f32(seed)) is a SPLAT: (seed,seed,seed).
//      prng(vec3<f32>(wrap, f32(seed)))      -> nm_prng(float3(wrap.x, wrap.y, seed))
//      prng(vec3<f32>(f32(seed), wrap))      -> nm_prng(float3(seed, wrap.x, wrap.y))
//  * atan2(st.x, st.y) — arg order copied literally (H3).
//  * select(delta/maxc, 0.0, maxc==0.0) -> (maxc==0.0) ? 0.0 : delta/maxc (rgb2hsv
//    is dead code here but ported for fidelity).
//  * modulo() -> nm_mod (NEVER fmod). mix -> lerp. fract -> frac.
//  * mat3x3<f32> constants are COLUMN-MAJOR in WGSL; reproduced as float3x3 with
//    the same column vectors and matrix*vector via explicit column combination to
//    avoid HLSL's row-major mul() transpose.
//  * `shape` is BOTH a uniform (the metric enum) and a WGSL function name; the
//    function is renamed nm_cn_shape here, the uniform stays `shape`.
//  * `let speed = floor(speed);` shadows the param inside cells(); reproduced.
//  * pal() uses TAU (6.28318530718) per WGSL (GLSL used the literal 6.28318).
//  * Full 32-bit float; PCG is bit-sensitive (no half/min16float).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Optional input surface + sampler (WGSL: tex@2, samp@1) ------------------
Texture2D    tex;
SamplerState sampler_tex;

// ---- Per-effect named uniforms (definition.js globals[*].uniform) ------------
// Bound by the runtime via MaterialPropertyBlock under these exact names.
int    shape;          // metric enum (circle 0, diamond 1, hexagon 2, octagon 3, square 4, triangle 6)
float  scale;          // [1,100]  default 75
float  cellScale;      // [1,100]  default 87
float  cellSmooth;     // [0,100]  default 11  (global key "smooth")
float  variation;      // [0,100]  default 50  (cellVariation)
float  speed;          // [0,5]    default 1   (declared float; WGSL reads data[2].y as f32)
int    paletteMode;    // default 4 (WGSL only special-cases 1=hsv, 2=oklab)
int    seed;           // [1,100]  default 1
int    colorMode;      // mono 0 / monoInverse 1 / palette 2   default 0
float3 paletteOffset;  // default (0.5,0.5,0.5)
int    cyclePalette;   // off 0 / forward 1 / backward -1      default 1
float3 paletteAmp;     // default (0.5,0.5,0.5)
float  rotatePalette;  // [0,100]  default 0
float3 paletteFreq;    // default (2,2,2)
float  repeatPalette;  // [1,10]   default 1  (declared float; WGSL reads data[5].w as f32)
float3 palettePhase;   // default (1,1,1)
int    texInfluence;   // enum: 1,2 (warp-ish) / 10..16 (post-d ops)   default 2
float  texIntensity;   // [0,100]  default 0

// Local PI/TAU exactly as the WGSL declares them.
static const float NMCN_PI  = 3.14159265359;
static const float NMCN_TAU = 6.28318530718;

// ---- modulo (per-effect copy; == nm_mod) ------------------------------------
float nmcn_modulo(float a, float b)
{
    return a - b * floor(a / b);
}

// ---- map (per-effect copy) --------------------------------------------------
float nmcn_map(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

// ---- hsv2rgb (per-effect copy) ----------------------------------------------
float3 nmcn_hsv2rgb(float3 hsv)
{
    float h = frac(hsv.x);
    float s = hsv.y;
    float v = hsv.z;

    float c = v * s;
    float x = c * (1.0 - abs(nmcn_modulo(h * 6.0, 2.0) - 1.0));
    float m = v - c;

    float3 rgb = float3(0.0, 0.0, 0.0);
    if (0.0 <= h && h < 1.0 / 6.0) {
        rgb = float3(c, x, 0.0);
    } else if (1.0 / 6.0 <= h && h < 2.0 / 6.0) {
        rgb = float3(x, c, 0.0);
    } else if (2.0 / 6.0 <= h && h < 3.0 / 6.0) {
        rgb = float3(0.0, c, x);
    } else if (3.0 / 6.0 <= h && h < 4.0 / 6.0) {
        rgb = float3(0.0, x, c);
    } else if (4.0 / 6.0 <= h && h < 5.0 / 6.0) {
        rgb = float3(x, 0.0, c);
    } else if (5.0 / 6.0 <= h && h < 1.0) {
        rgb = float3(c, 0.0, x);
    }

    return rgb + float3(m, m, m);
}

// ---- rgb2hsv (per-effect copy; dead in main but ported for fidelity) --------
float3 nmcn_rgb2hsv(float3 rgb)
{
    float r = rgb.r;
    float g = rgb.g;
    float b = rgb.b;

    float maxc = max(r, max(g, b));
    float minc = min(r, min(g, b));
    float delta = maxc - minc;

    float h = 0.0;
    if (delta != 0.0) {
        if (maxc == r) {
            h = nmcn_modulo((g - b) / delta, 6.0) / 6.0;
        } else if (maxc == g) {
            h = ((b - r) / delta + 2.0) / 6.0;
        } else if (maxc == b) {
            h = ((r - g) / delta + 4.0) / 6.0;
        }
    }

    // WGSL: select(delta / maxc, 0.0, maxc == 0.0)
    float s = (maxc == 0.0) ? 0.0 : delta / maxc;
    float v = maxc;

    return float3(h, s, v);
}

// ---- linearToSrgb (per-effect copy) -----------------------------------------
float3 nmcn_linearToSrgb(float3 lin)
{
    float3 srgb = float3(0.0, 0.0, 0.0);
    [unroll]
    for (int i = 0; i < 3; i = i + 1) {
        if (lin[i] <= 0.0031308) {
            srgb[i] = lin[i] * 12.92;
        } else {
            srgb[i] = 1.055 * pow(lin[i], 1.0 / 2.4) - 0.055;
        }
    }
    return srgb;
}

// ---- oklab fwd/inv matrices (WGSL column-major; applied column-wise) ---------
// WGSL mat3x3<f32>(col0, col1, col2); M * v = col0*v.x + col1*v.y + col2*v.z.
static const float3 NMCN_fwdA0 = float3(1.0, 1.0, 1.0);
static const float3 NMCN_fwdA1 = float3(0.3963377774, -0.1055613458, -0.0894841775);
static const float3 NMCN_fwdA2 = float3(0.2158037573, -0.0638541728, -1.2914855480);

static const float3 NMCN_fwdB0 = float3(4.0767245293, -1.2681437731, -0.0041119885);
static const float3 NMCN_fwdB1 = float3(-3.3072168827, 2.6093323231, -0.7034763098);
static const float3 NMCN_fwdB2 = float3(0.2307590544, -0.3411344290, 1.7068625689);

static const float3 NMCN_invB0 = float3(0.4121656120, 0.2118591070, 0.0883097947);
static const float3 NMCN_invB1 = float3(0.5362752080, 0.6807189584, 0.2818474174);
static const float3 NMCN_invB2 = float3(0.0514575653, 0.1074065790, 0.6302613616);

static const float3 NMCN_invA0 = float3(0.2104542553, 1.9779984951, 0.0259040371);
static const float3 NMCN_invA1 = float3(0.7936177850, -2.4285922050, 0.7827717662);
static const float3 NMCN_invA2 = float3(-0.0040720468, 0.4505937099, -0.8086757660);

float3 nmcn_mulCol(float3 c0, float3 c1, float3 c2, float3 v)
{
    return c0 * v.x + c1 * v.y + c2 * v.z;
}

float3 nmcn_oklab_from_linear_srgb(float3 c)
{
    float3 lms = nmcn_mulCol(NMCN_invB0, NMCN_invB1, NMCN_invB2, c);
    return nmcn_mulCol(NMCN_invA0, NMCN_invA1, NMCN_invA2,
                       sign(lms) * pow(abs(lms), float3(0.3333333333333, 0.3333333333333, 0.3333333333333)));
}

float3 nmcn_linear_srgb_from_oklab(float3 c)
{
    float3 lms = nmcn_mulCol(NMCN_fwdA0, NMCN_fwdA1, NMCN_fwdA2, c);
    return nmcn_mulCol(NMCN_fwdB0, NMCN_fwdB1, NMCN_fwdB2, lms * lms * lms);
}

// ---- pal (per-effect copy) --------------------------------------------------
float3 nmcn_pal(float t0, float3 pOffset, float3 pAmp, float3 pFreq, float3 pPhase,
                int pMode, float rotPalette, float repPalette)
{
    float t = t0 * repPalette + rotPalette * 0.01;
    float3 color = pOffset + pAmp * cos(NMCN_TAU * (pFreq * t + pPhase));

    if (pMode == 1) {
        color = nmcn_hsv2rgb(color);
    } else if (pMode == 2) {
        color.g = color.g * -0.509 + 0.276;
        color.b = color.b * -0.509 + 0.198;
        color = nmcn_linear_srgb_from_oklab(color);
        color = nmcn_linearToSrgb(color);
    }
    return color;
}

// ---- luminance (per-effect copy) --------------------------------------------
float nmcn_luminance(float3 color)
{
    return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
}

// ---- polarShape (atan2 arg order copied literally) --------------------------
float nmcn_polarShape(float2 st, int sides)
{
    float a = atan2(st.x, st.y) + NMCN_PI;
    float r = NMCN_TAU / (float)sides;
    return cos(floor(0.5 + a / r) * r - a) * length(st);
}

// ---- shape (WGSL fn `shape`; renamed to avoid clash with uniform `shape`) ----
float nm_cn_shape(float2 st0, float2 offset, int kind, float scl)
{
    float2 st = st0 + offset;
    float d = 1.0;
    if (kind == 0) {
        d = length(st * 1.2);
    } else if (kind == 2) {
        d = nmcn_polarShape(st * 1.2, 6);
    } else if (kind == 3) {
        d = nmcn_polarShape(st * 1.2, 8);
    } else if (kind == 4) {
        d = nmcn_polarShape(st * 1.5, 4);
    } else if (kind == 6) {
        float2 st2 = st;
        st2.y = st2.y + 0.05;
        d = nmcn_polarShape(st2 * 1.5, 3);
    }
    return d * scl;
}

// ---- smin (per-effect copy) -------------------------------------------------
float nmcn_smin(float a, float b, float k)
{
    if (k == 0.0) { return min(a, b); }
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// ---- cells (Worley distance evaluation) -------------------------------------
float nmcn_cells(float2 st0, float freq, float cellSize, int metric, int seedV,
                 float speedV, float cellVariation, float cellSmoothV, float timeV, float aspect)
{
    float2 st = st0;
    st = st - float2(0.5 * aspect, 0.5);
    st = st * freq;
    st = st + float2(0.5 * aspect, 0.5);
    // WGSL: prng(vec3<f32>(f32(seed))).xy  -> splat (seed,seed,seed)
    st = st + nm_prng(float3((float)seedV, (float)seedV, (float)seedV)).xy;

    float2 i = floor(st);
    float2 f = frac(st);

    float d = 1.0;
    [loop]
    for (int y = -2; y <= 2; y = y + 1) {
        [loop]
        for (int x = -2; x <= 2; x = x + 1) {
            float2 n = float2((float)x, (float)y);
            float2 wrap = i + n;
            // wrap = wrapEdges(wrap, freq, aspect);   // (commented out in source)
            // WGSL: prng(vec3<f32>(wrap, f32(seed))).xy -> (wrap.x, wrap.y, seed)
            // NOTE: WGSL local `point` renamed; `point` is an HLSL reserved keyword.
            float2 pointJitter = nm_prng(float3(wrap.x, wrap.y, (float)seedV)).xy;

            // WGSL: prng(vec3<f32>(f32(seed), wrap)) -> (seed, wrap.x, wrap.y)
            float3 r1 = nm_prng(float3((float)seedV, wrap.x, wrap.y)) * 0.5 - float3(0.25, 0.25, 0.25);
            // WGSL: prng(vec3<f32>(wrap, f32(seed)))  -> (wrap.x, wrap.y, seed)
            float3 r2 = nm_prng(float3(wrap.x, wrap.y, (float)seedV)) * 2.0 - float3(1.0, 1.0, 1.0);
            float spd = floor(speedV);  // WGSL: let speed = floor(speed);
            pointJitter = pointJitter + float2(
                sin(timeV * NMCN_TAU * spd + r2.x) * r1.x,
                cos(timeV * NMCN_TAU * spd + r2.y) * r1.y
            );

            float2 diff = n + pointJitter - f;
            float dist = nm_cn_shape(float2(diff.x, -diff.y), float2(0.0, 0.0), metric, cellSize);
            if (metric == 1) {
                dist = abs(n.x + pointJitter.x - f.x) + abs(n.y + pointJitter.y - f.y);
                dist = dist * cellSize;
            }

            dist = dist + r1.z * (cellVariation * 0.01);
            d = nmcn_smin(d, dist, cellSmoothV * 0.01);
        }
    }
    return d;
}

// =============================================================================
// nm_cellNoise — core per-pixel evaluation. Mirrors WGSL main() exactly.
//   globalCoord = NM_GlobalCoord(i) = pos.xy + tileOffset (top-left, +0.5).
//   texel = already-sampled `tex` RGBA at texCoord (caller does the sample so the
//           Shader Graph wrapper can supply it). texCoord = globalCoord/fullRes.
// =============================================================================
float4 nm_cellNoise(float2 globalCoord, float2 res, float2 fullRes, float timeV, float4 texel)
{
    int   metric        = shape;
    float scaleV        = scale;
    float cellScaleV    = cellScale;
    float cellSmoothV   = cellSmooth;
    float cellVariation = variation;
    float speedV        = speed;
    int   paletteModeV  = paletteMode;
    int   colorModeV    = colorMode;
    int   cyclePaletteV = cyclePalette;
    int   texInfluenceV = texInfluence;
    float texIntensityV = texIntensity;
    int   seedV         = seed;

    float aspect = res.x / res.y;

    float4 color = float4(0.0, 0.0, 1.0, 1.0);
    float2 st = globalCoord / fullRes.y;   // DIVIDE BY HEIGHT

    float freq = nmcn_map(scaleV, 1.0, 100.0, 20.0, 1.0);
    float cellSize = nmcn_map(cellScaleV, 1.0, 100.0, 3.0, 0.75);

    float texLuminosity = 0.0;
    float texFactor = texIntensityV * 0.01;

    if (texInfluenceV > 0) {
        float3 texRGB = texel.rgb;
        texLuminosity = nmcn_luminance(texRGB);

        if (texInfluenceV == 1) {
            cellSize = cellSize - texLuminosity * texFactor;
        } else if (texInfluenceV == 2) {
            freq = freq - texLuminosity * (texFactor * 5.0);
        }
    }

    float d = nmcn_cells(st, freq, cellSize, metric, seedV, speedV, cellVariation, cellSmoothV, timeV, aspect);

    if (texInfluenceV >= 10) {
        if (texInfluenceV == 10) {
            d = d + texLuminosity * texFactor;
        } else if (texInfluenceV == 11) {
            d = lerp(d, d / max(0.1, texLuminosity), texFactor);
        } else if (texInfluenceV == 12) {
            d = lerp(d, min(d, texLuminosity), texFactor);
        } else if (texInfluenceV == 13) {
            d = lerp(d, max(d, texLuminosity), texFactor);
        } else if (texInfluenceV == 14) {
            d = lerp(d, nmcn_modulo(d, max(0.1, texLuminosity)), texFactor);
        } else if (texInfluenceV == 15) {
            d = lerp(d, d * texLuminosity, texFactor);
        } else if (texInfluenceV == 16) {
            d = d - texLuminosity * texFactor;
        }
    }

    if (colorModeV == 0) {
        color = float4(float3(d, d, d), color.a);
    } else if (colorModeV == 1) {
        color = float4(float3(1.0 - d, 1.0 - d, 1.0 - d), color.a);
    } else if (colorModeV == 2) {
        float dd = d;
        if (cyclePaletteV == -1) {
            dd = dd + timeV;
        } else if (cyclePaletteV == 1) {
            dd = dd - timeV;
        }
        color = float4(nmcn_pal(dd, paletteOffset, paletteAmp, paletteFreq, palettePhase,
                                paletteModeV, rotatePalette, repeatPalette), color.a);
    }

    return color;
}

// ---- Pass: "cellNoise" (progName "cellNoise") -------------------------------
float4 NMFrag_cellNoise(NMVaryings i) : SV_Target
{
    float2 globalCoord = NM_GlobalCoord(i);
    // WGSL: texCoord = (pos.xy + tileOffset) / fullResolution (both axes).
    float2 texCoord = globalCoord / fullResolution;
    float4 texel = tex.Sample(sampler_tex, texCoord);
    return nm_cellNoise(globalCoord, resolution, fullResolution, time, texel);
}

#endif // NM_EFFECT_CELLNOISE_INCLUDED
