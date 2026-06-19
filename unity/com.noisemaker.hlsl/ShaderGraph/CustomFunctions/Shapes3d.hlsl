#ifndef NM_SG_SHAPES3D_INCLUDED
#define NM_SG_SHAPES3D_INCLUDED

// =============================================================================
// Shapes3d.hlsl — Shader Graph Custom Function wrapper for
// classicNoisedeck/shapes3d.
//
// Invokes the full raymarcher inline. The three "define" uniforms (SHAPE_A,
// SHAPE_B, BLEND_MODE) must be provided as integer inputs; the [branch]
// attributes in Shapes3d.hlsl ensure the GPU can constant-fold them when the
// graph bakes them as literal integers.
//
// Signature follows the filter convention:
//   (UnityTexture2D InputTex, UnitySamplerState SS, float2 UV, float2 Resolution,
//    ... params ..., out float4 Out)
// UV is the fullscreen (0..1) UV; Resolution is the full (untiled) resolution.
//
// NOTE: this wrapper calls the full raymarcher (100 march steps × 4 normal
// probes = 404 getDist() calls per pixel). GPU budget is significant; prefer
// the render-pass route (Shapes3d.shader) for real-time use in the Noisemaker
// pipeline.
// =============================================================================

// Pull in Shapes3d.hlsl which includes NMFullscreen.hlsl for NM_* macros.
// In a Shader Graph context the graph's own SamplerState is used; the bare
// `inputTex` + `sampler_inputTex` declarations in Shapes3d.hlsl are overridden
// by the CustomFunction node's inputs (the SG compiler merges them).
#include "../../Shaders/Effects/classicNoisedeck/Shapes3d.hlsl"

void NM_Shapes3d_float(
    // Input texture (optional triplanar projection; set weight=0 to ignore)
    UnityTexture2D InputTex,
    UnitySamplerState SS,
    // Screen UV (0..1 top-left origin)
    float2 UV,
    // Resolution = full (untiled) render target size in pixels
    float2 Resolution,
    // Shape selectors (maps to SHAPE_A / SHAPE_B / BLEND_MODE int uniforms)
    int ShapeA,
    int ShapeB,
    int BlendMode,
    // Shape parameters
    float ShapeAScale,
    float ShapeBScale,
    float ShapeAThickness,
    float ShapeBThickness,
    float Smoothness,
    // Repetition
    float Repetition,
    float Animation,
    float FlythroughSpeed,
    float Spacing,
    // Rotation
    float Spin,
    float SpinSpeed,
    float Flip,
    float FlipSpeed,
    // Camera
    float CameraDist,
    // Color
    float3 BgColor,
    float BgAlpha,
    float Weight,
    float ColorMode,
    // Palette
    float3 PaletteOffset,
    float3 PaletteAmp,
    float3 PaletteFreq,
    float3 PalettePhase,
    float CyclePalette,
    float RotatePalette,
    float RepeatPalette,
    float PaletteMode,
    // Output
    out float4 Out)
{
    // Bind graph inputs to the module-level uniforms declared in Shapes3d.hlsl.
    SHAPE_A         = ShapeA;
    SHAPE_B         = ShapeB;
    BLEND_MODE      = BlendMode;
    shapeAScale     = ShapeAScale;
    shapeBScale     = ShapeBScale;
    shapeAThickness = ShapeAThickness;
    shapeBThickness = ShapeBThickness;
    smoothness      = Smoothness;
    repetition      = Repetition;
    animation       = Animation;
    flythroughSpeed = FlythroughSpeed;
    spacing         = Spacing;
    spin            = Spin;
    spinSpeed       = SpinSpeed;
    flip            = Flip;
    flipSpeed       = FlipSpeed;
    cameraDist      = CameraDist;
    bgColor         = BgColor;
    bgAlpha         = BgAlpha;
    weight          = Weight;
    colorMode       = ColorMode;
    paletteOffset   = PaletteOffset;
    paletteAmp      = PaletteAmp;
    paletteFreq     = PaletteFreq;
    palettePhase    = PalettePhase;
    cyclePalette    = CyclePalette;
    rotatePalette   = RotatePalette;
    repeatPalette   = RepeatPalette;
    paletteMode     = PaletteMode;

    // Override the texture/sampler bindings so the graph's inputs are used.
    inputTex         = InputTex.tex;
    sampler_inputTex = SS.samplerstate;

    // st = (UV * Resolution - 0.5 * Resolution) / Resolution.y
    // matches the WGSL: ((pos.xy + tileOffset) - 0.5*fullResolution) / fullResolution.y
    // In this SG context tileOffset == 0 and pos.xy == UV * Resolution.
    float2 pos = UV * Resolution;
    float2 st  = (pos - 0.5 * Resolution) / Resolution.y;

    float3 rayOrigin    = float3(0.0, 0.0, -cameraDist);
    float3 rayDirection = normalize(float3(st, 1.0));
    float  d            = shapes3d_rayMarch(rayOrigin, rayDirection);

    float3 p             = rayOrigin + rayDirection * d;
    float3 lightPosition = float3(-5.0, 5.0, -5.0);
    float3 lightVector   = normalize(lightPosition - p);
    float3 normal        = shapes3d_getNormal(p);
    float  diff          = clamp(dot(normal, lightVector), 0.0, 1.0);

    float4 color = float4(1.0, 1.0, 1.0, 1.0);

    if (weight > 0.0) {
        float3 tp = shapes3d_applyTransform(p);
        tp = tp * 0.5 + float3(0.5, 0.5, 0.5);
        float3 absN   = abs(normal);
        float3 cXY = inputTex.Sample(sampler_inputTex, tp.xy).rgb;
        float3 cXZ = inputTex.Sample(sampler_inputTex, tp.xz).rgb;
        float3 cYZ = inputTex.Sample(sampler_inputTex, tp.yz).rgb;
        color = float4(cXY * absN.z + cXZ * absN.y + cYZ * absN.x, 1.0);
    }

    int iColorMode = (int)round(colorMode);
    [branch]
    if (iColorMode == 0) {
        float fog0 = 1.0 - clamp(d * 0.035, 0.0, 1.0);
        color = float4(color.rgb * float3(fog0, fog0, fog0), color.a);
    } else if (iColorMode == 1) {
        color = float4(color.rgb * (float3(diff * 1.5, diff * 1.5, diff * 1.5) + float3(0.5, 0.5, 0.5)), color.a);
    } else if (iColorMode == 10) {
        color = float4(color.rgb * (float3(diff * 1.5, diff * 1.5, diff * 1.5) + float3(0.5, 0.5, 0.5)), color.a);
        float lum  = shapes3d_luminance(color.rgb);
        int iCycle = (int)round(cyclePalette);
        if (iCycle == -1) { lum = lum + time; }
        else if (iCycle == 1) { lum = lum - time; }
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

    Out = color;
}

#endif // NM_SG_SHAPES3D_INCLUDED
