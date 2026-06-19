#ifndef NM_HISTORICPALETTE_INCLUDED
#define NM_HISTORICPALETTE_INCLUDED

// =============================================================================
// HistoricPalette.hlsl — filter/historicPalette, ported PIXEL-IDENTICALLY from
//   shaders/effects/filter/historicPalette/wgsl/historicPalette.wgsl
//
// Maps input luminance to 5-color historical art palettes.
// No per-effect helpers beyond palette data — no PRNG, no atan2, no select().
//
// PORTING-GUIDE notes:
//  * Single render pass (definition.js passes[0].program "historicPalette").
//  * uv = pos.xy / textureDimensions(inputTex) — divide by INPUT TEXTURE size,
//    NOT by fullResolution. Mirrored exactly via NM_FragCoord(i) / GetDimensions.
//  * rotation: WGSL reads as i32(uniforms.data[0].z). Definition.js types it
//    `float` with choices {none:0,fwd:1,back:-1}. We declare `float rotation`
//    (matching uniform name) and compare as int to match WGSL's i32 cast.
//  * All palette constants are literal float3 values from the WGSL — not indexed
//    by preprocessor. An HLSL static const array of structs is used.
//  * sampleHistoricPalette: ported VERBATIM — smoothstep thresholds, blendWidth,
//    cascade mix, wrap-around branch with cyclic distance. WGSL uses `if (lum >
//    0.5)` — mirrored as-is (no select).
//  * fract(t) → frac(t). mix → lerp. vec3f → float3. f32 → float.
//  * No fast-math; no arithmetic simplification.
//  * Linear, clamp-to-edge, non-sRGB sampler (H7).
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (definition.js globals[*].uniform) -----------
int   paletteIndex;  // globals.index.uniform   "paletteIndex", default 4
float smoothness;    // globals.smoothness.uniform "smoothness", default 0
float rotation;      // globals.rotation.uniform  "rotation",   default 0
float offset;        // globals.offset.uniform    "offset",     default 0
float repeat;        // globals.repeat.uniform    "repeat",     default 1
float alpha;         // globals.alpha.uniform     "alpha",      default 1
// Note: `time` is provided by NMFullscreen.hlsl as the engine global `time`.

// -----------------------------------------------------------------------------
// Palette table — 21 entries, 5 float3 colors each, darkest→lightest.
// Values are copied VERBATIM from the WGSL const array.
// -----------------------------------------------------------------------------
struct HistoricPalette
{
    float3 color1;  // darkest
    float3 color2;
    float3 color3;
    float3 color4;
    float3 color5;  // lightest
};

static const int PALETTE_COUNT = 21;

static const HistoricPalette palettes[21] = {
    // 0: Aboriginal Australian Dot Painting
    { float3(0.165, 0.102, 0.039), float3(0.914, 0.769, 0.416),
      float3(0.627, 0.322, 0.176), float3(0.957, 0.894, 0.843),
      float3(0.545, 0.271, 0.075) },
    // 1: Abstract Expressionism
    { float3(0.306, 0.204, 0.180), float3(0.827, 0.184, 0.184),
      float3(0.980, 0.980, 0.980), float3(0.098, 0.463, 0.824),
      float3(0.976, 0.659, 0.145) },
    // 2: Art Deco
    { float3(0.039, 0.039, 0.039), float3(0.831, 0.686, 0.216),
      float3(0.173, 0.373, 0.435), float3(0.961, 0.961, 0.863),
      float3(0.769, 0.118, 0.227) },
    // 3: Art Nouveau
    { float3(0.361, 0.514, 0.455), float3(0.659, 0.776, 0.525),
      float3(0.957, 0.894, 0.757), float3(0.910, 0.706, 0.627),
      float3(0.608, 0.494, 0.741) },
    // 4: Bauhaus
    { float3(0.102, 0.102, 0.102), float3(0.969, 0.925, 0.075),
      float3(0.059, 0.278, 0.686), float3(1.000, 1.000, 1.000),
      float3(0.890, 0.118, 0.141) },
    // 5: Cave Art
    { float3(0.173, 0.094, 0.063), float3(0.871, 0.722, 0.529),
      float3(0.545, 0.271, 0.075), float3(0.961, 0.902, 0.827),
      float3(0.824, 0.412, 0.118) },
    // 6: Chinese Ink
    { float3(0.102, 0.102, 0.102), float3(0.290, 0.290, 0.290),
      float3(0.502, 0.502, 0.502), float3(0.749, 0.749, 0.749),
      float3(0.961, 0.961, 0.941) },
    // 7: Dutch Golden Age
    { float3(0.290, 0.055, 0.055), float3(0.553, 0.431, 0.388),
      float3(0.243, 0.149, 0.137), float3(0.831, 0.647, 0.455),
      float3(0.106, 0.369, 0.125) },
    // 8: Fauvism
    { float3(0.482, 0.176, 0.149), float3(0.361, 0.294, 0.600),
      float3(0.290, 0.486, 0.349), float3(0.957, 0.635, 0.380),
      float3(1.000, 0.420, 0.208) },
    // 9: Impressionism
    { float3(0.722, 0.651, 0.851), float3(0.769, 0.910, 0.761),
      float3(0.910, 0.769, 0.627), float3(0.902, 0.835, 0.722),
      float3(0.659, 0.847, 0.918) },
    // 10: Indian Miniature
    { float3(0.082, 0.263, 0.376), float3(0.118, 0.518, 0.286),
      float3(0.769, 0.118, 0.227), float3(0.953, 0.612, 0.071),
      float3(0.988, 0.953, 0.812) },
    // 11: Islamic Geometric
    { float3(0.000, 0.306, 0.537), float3(0.000, 0.549, 0.549),
      float3(0.831, 0.686, 0.216), float3(0.545, 0.000, 0.000),
      float3(0.973, 0.973, 0.941) },
    // 12: Kente Cloth
    { float3(0.000, 0.000, 0.000), float3(0.000, 0.322, 0.647),
      float3(0.808, 0.067, 0.149), float3(0.000, 0.620, 0.286),
      float3(0.992, 0.725, 0.075) },
    // 13: Maori Carving
    { float3(0.173, 0.094, 0.063), float3(0.824, 0.706, 0.549),
      float3(0.396, 0.263, 0.129), float3(0.961, 0.961, 0.863),
      float3(0.545, 0.271, 0.075) },
    // 14: Mexican Muralism
    { float3(0.004, 0.341, 0.608), float3(0.847, 0.263, 0.082),
      float3(0.337, 0.545, 0.184), float3(0.365, 0.251, 0.216),
      float3(0.976, 0.659, 0.145) },
    // 15: Minimalism
    { float3(0.259, 0.259, 0.259), float3(0.620, 0.620, 0.620),
      float3(0.110, 0.110, 0.110), float3(0.878, 0.878, 0.878),
      float3(0.961, 0.961, 0.961) },
    // 16: Persian Miniature
    { float3(0.608, 0.349, 0.714), float3(0.086, 0.627, 0.522),
      float3(0.906, 0.298, 0.235), float3(0.953, 0.612, 0.071),
      float3(0.925, 0.941, 0.945) },
    // 17: Pop Art
    { float3(0.914, 0.118, 0.388), float3(1.000, 0.922, 0.231),
      float3(0.161, 0.475, 1.000), float3(1.000, 0.090, 0.267),
      float3(0.000, 0.902, 0.463) },
    // 18: Renaissance
    { float3(0.184, 0.310, 0.184), float3(0.545, 0.455, 0.333),
      float3(0.545, 0.000, 0.000), float3(0.855, 0.647, 0.125),
      float3(0.098, 0.098, 0.439) },
    // 19: Surrealism
    { float3(0.216, 0.278, 0.310), float3(0.961, 0.486, 0.000),
      float3(0.290, 0.078, 0.549), float3(1.000, 0.878, 0.510),
      float3(0.000, 0.412, 0.361) },
    // 20: Ukiyo-e
    { float3(0.118, 0.302, 0.545), float3(0.910, 0.698, 0.596),
      float3(0.176, 0.314, 0.086), float3(0.957, 0.910, 0.757),
      float3(0.769, 0.118, 0.227) }
};

// -----------------------------------------------------------------------------
// sampleHistoricPalette — ported VERBATIM from WGSL fn sampleHistoricPalette().
// Maps luminance [0..1] to a palette color using 5 thresholds and optional
// smoothstep blending. Wrap-around zone blends color5->color1 at the frac seam.
// -----------------------------------------------------------------------------
float3 sampleHistoricPalette(HistoricPalette pal, float lum, float smoothAmount)
{
    // WGSL: define the 5 luminance thresholds (equal subdivisions)
    float t1 = 0.2;
    float t2 = 0.4;
    float t3 = 0.6;
    float t4 = 0.8;

    // Calculate blend width based on smoothness (0 = hard edge, 1 = full blend)
    // Maximum blend width is 0.1 (half the distance between thresholds)
    float blendWidth = smoothAmount * 0.1;

    // Calculate blend factors at each threshold using smoothstep
    float b1 = smoothstep(t1 - blendWidth, t1 + blendWidth, lum);
    float b2 = smoothstep(t2 - blendWidth, t2 + blendWidth, lum);
    float b3 = smoothstep(t3 - blendWidth, t3 + blendWidth, lum);
    float b4 = smoothstep(t4 - blendWidth, t4 + blendWidth, lum);

    // Cascade blends: start with color1, blend toward each successive color
    float3 result = lerp(pal.color1, pal.color2, b1);
    result = lerp(result, pal.color3, b2);
    result = lerp(result, pal.color4, b3);
    result = lerp(result, pal.color5, b4);

    // Wrap-around blend: smooth the seam between color5 and color1
    // WGSL: if (blendWidth > 0.0) { ... }
    if (blendWidth > 0.0)
    {
        // Signed cyclic distance from the wrap boundary (t=0 == t=1)
        float d;
        if (lum > 0.5)
        {
            d = lum - 1.0;
        }
        else
        {
            d = lum;
        }
        // Interpolation factor: 0 = color5, 1 = color1
        float wrapFactor = smoothstep(-blendWidth, blendWidth, d);
        float3 wrapColor = lerp(pal.color5, pal.color1, wrapFactor);
        // Mask: 1.0 at wrap point, fading to 0.0 at edge of zone
        float wrapMask = 1.0 - smoothstep(0.0, blendWidth, abs(d));
        result = lerp(result, wrapColor, wrapMask);
    }

    return result;
}

// -----------------------------------------------------------------------------
// nm_historicPalette — core per-pixel evaluation. Ported VERBATIM from WGSL
// main(). Takes the already-sampled input color and returns the palette-mapped
// RGBA, blended with the original by alpha.
// -----------------------------------------------------------------------------
float4 nm_historicPalette(float4 inputColor)
{
    // Clamp palette index to valid range
    // WGSL: let idx = clamp(paletteIndex, 0, PALETTE_COUNT - 1);
    int idx = clamp(paletteIndex, 0, PALETTE_COUNT - 1);

    // Calculate luminance
    // WGSL: let lum = dot(inputColor.rgb, vec3f(0.299, 0.587, 0.114));
    float lum = dot(inputColor.rgb, float3(0.299, 0.587, 0.114));

    // Apply palette modifiers: repeat, offset, and rotation (animation)
    // WGSL: var t = lum * (1.0 - 1e-4) * repeat + offset * 0.01;
    float t = lum * (1.0 - 1e-4) * repeat + offset * 0.01;

    // WGSL: if (rotation == -1) { t = t + time; } else if (rotation == 1) { t = t - time; }
    // rotation is a float uniform with choices {none:0,fwd:1,back:-1}; cast to int to match WGSL.
    int rot = (int)rotation;
    [branch]
    if (rot == -1)
    {
        t = t + time;
    }
    else if (rot == 1)
    {
        t = t - time;
    }

    // WGSL: t = fract(t);
    t = frac(t);

    // Get palette entry and sample color
    // WGSL: let pal = palettes[idx]; let paletteColor = sampleHistoricPalette(pal, t, smoothness);
    HistoricPalette pal = palettes[idx];
    float3 paletteColor = sampleHistoricPalette(pal, t, smoothness);

    // Blend between original and palette color based on alpha
    // WGSL: let blendedColor = mix(inputColor.rgb, paletteColor, alpha);
    float3 blendedColor = lerp(inputColor.rgb, paletteColor, alpha);

    // WGSL: return vec4f(blendedColor, inputColor.a);
    return float4(blendedColor, inputColor.a);
}

#endif // NM_HISTORICPALETTE_INCLUDED
