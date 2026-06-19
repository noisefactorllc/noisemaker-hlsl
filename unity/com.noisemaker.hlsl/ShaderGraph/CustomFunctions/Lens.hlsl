#ifndef NM_SG_LENS_INCLUDED
#define NM_SG_LENS_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/lens.
//
// Drops the lens distortion into Shader Graph as a node. Global params map to
// named inputs (matching definition.js globals[*].uniform):
//   displacement -> LensDisplacement (float) [-1,1]  default 0
//   aspectLens   -> AspectLens       (float) 0/1     default 1
//   antialias    -> Antialias        (float) 0/1     default 1
//
// UV must be the input texture's own 0..1 UV (fragCoord / inputTex dims). The
// resolution of the full (possibly untiled) frame is passed as FullResolution
// so the wrapper can replicate the WGSL `dims` selection logic.
// TileOffset must be passed as (0,0) for non-tiled Shader Graph use.
//
// Self-contained: does NOT include NMFullscreen.hlsl / NMCore.hlsl. Math is
// mirrored VERBATIM from Shaders/Effects/filter/Lens.hlsl.
// TODO(verify): SS must be a linear (non-sRGB), clamp-to-edge sampler (H7).
// =============================================================================

void NM_Lens_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    float2            FullResolution,
    float2            TileOffset,
    float             LensDisplacement,
    float             AspectLens,
    float             Antialias,
    out float4        Out)
{
    // texSize = textureDimensions(inputTex)
    float texW, texH;
    InputTex.tex.GetDimensions(texW, texH);
    float2 texSize = float2(texW, texH);

    // dims = (fullResolution.x > 0) ? fullResolution : texSize
    float2 dims = (FullResolution.x > 0.0) ? FullResolution : texSize;

    // isTile
    bool isTile = length(TileOffset) > 0.0;

    // uv = (fragCoord + tileOffset) / dims. Here UV is already fragCoord/texSize
    // so re-derive globalFragCoord and re-divide by dims.
    float2 fragCoord = UV * texSize;
    float2 uv = (fragCoord + TileOffset) / dims;

    // zoom for negative displacement (pincushion)
    float zoom = 0.0;
    if (LensDisplacement < 0.0)
    {
        zoom = LensDisplacement * -0.25;
    }

    float aspect = dims.x / dims.y;
    float2 dist = uv - (float2)0.5;
    float2 aDist = dist;
    if (AspectLens > 0.5) { aDist.x = aDist.x * aspect; }

    float halfAspect = (AspectLens > 0.5) ? (aspect * 0.5) : 0.5;
    float maxDist = length(float2(halfAspect, 0.5));
    float distFromCenter = length(aDist);
    float normalizedDist = clamp(distFromCenter / maxDist, 0.0, 1.0);

    float centerWeight = 1.0 - normalizedDist;
    float centerWeightSq = centerWeight * centerWeight;

    float2 displacement = aDist * zoom + aDist * centerWeightSq * LensDisplacement;

    if (AspectLens > 0.5) { displacement.x = displacement.x / aspect; }

    float2 offset;

    if (isTile)
    {
        float maxDispPixels = 256.0;
        float dispPixels = length(displacement * dims);
        if (dispPixels > maxDispPixels)
        {
            displacement = displacement * (maxDispPixels / dispPixels);
        }
        float2 warpedGlobalUV = uv - displacement;
        offset = (warpedGlobalUV * dims - TileOffset) / texSize;
    }
    else
    {
        offset = frac(uv - displacement);
    }

    if (Antialias > 0.5)
    {
        float2 dx = ddx(offset);
        float2 dy = ddy(offset);
        float4 col = (float4)0.0;
        col += SAMPLE_TEXTURE2D_GRAD(InputTex.tex, SS.samplerstate, offset + dx * -0.375 + dy * -0.125, dx, dy);
        col += SAMPLE_TEXTURE2D_GRAD(InputTex.tex, SS.samplerstate, offset + dx *  0.125 + dy * -0.375, dx, dy);
        col += SAMPLE_TEXTURE2D_GRAD(InputTex.tex, SS.samplerstate, offset + dx *  0.375 + dy *  0.125, dx, dy);
        col += SAMPLE_TEXTURE2D_GRAD(InputTex.tex, SS.samplerstate, offset + dx * -0.125 + dy *  0.375, dx, dy);
        Out = col * 0.25;
    }
    else
    {
        Out = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, offset);
    }
}

#endif // NM_SG_LENS_INCLUDED
