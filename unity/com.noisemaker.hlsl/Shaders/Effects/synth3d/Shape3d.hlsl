#ifndef NM_EFFECT_SHAPE3D_INCLUDED
#define NM_EFFECT_SHAPE3D_INCLUDED

// =============================================================================
// Shape3d.hlsl — synth3d/shape3d (func: "shape3d")
//
// 3D polyhedral / primitive SHAPE-VOLUME GENERATOR. Ported PIXEL-IDENTICALLY
// from the canonical WGSL source (top-left origin, no per-effect Y flip):
//   wgsl/precompute.wgsl   progName "precompute"   (frag_precompute)
//
// VOLUME-WRITE PASS (single pass). This is a 3D-tier generator: it does NOT
// render a 2D image. It fills a 2D ATLAS RenderTexture of size
// volumeSize x volumeSize^2 (default 64 x 4096 = 64 stacked 64x64 z-slices),
// stored rgba16f. Each atlas texel (x, yAtlas) maps to a 3D voxel:
//     x = x ; y = yAtlas % volumeSize ; z = yAtlas / volumeSize
// (reference 04 §8 vol0..7; reference 10 §3.7/§4.2 volume layout).
//
// MRT — drawBuffers:2:
//   SV_Target0 (color)  -> volumeCache atlas: rgba = (d, d, d, 1) scalar field.
//   SV_Target1 (geoOut) -> geoBuffer  atlas: xyz = packed normal (n*0.5+0.5),
//                          w = d (the scalar field value, == depth slot).
// The runtime binds outputs { color: volumeCache, geoOut: geoBuffer } and
// presents the volume downstream to render/render3d (or renderLit3d), which
// RAYMARCH the atlas into a screen image. shape3d itself performs no raymarch.
//
// This effect takes NO input texture. It reads only named uniforms + engine
// `time`. The atlas write uses fragCoord (NM_FragCoord, top-left, +0.5) which
// for an atlas-sized viewport indexes integer texels directly.
//
// NOTE: 3D / multi-output (MRT) / atlas-write effect → ships as a runtime-
// rendered Texture2D atlas. NO Shader Graph Custom Function wrapper is
// provided (the C# runtime drives the volume-write pass and the downstream
// raymarch separately; the atlas is not a Shader-Graph-shaped single output).
//
// PORTING-GUIDE / parity notes:
//  * Helpers (map_range/periodicFunction/all *SDF/shapeSDF/offset3D/
//    computeValue) ported verbatim, inline. NONE come from NMCore (no
//    pcg/prng/random/nm_mod used by this effect — there is no float mod here).
//  * WGSL `position` (@builtin(position), top-left, +0.5) → NM_FragCoord(i).
//    int(position.x/.y) truncates the +0.5-centered coord to the integer
//    texel index; reproduced with (int) casts after NM_FragCoord.
//  * GLSL `mod` (the GLSL source) is the int `%` here (yAtlas % volSize,
//    yAtlas / volSize) on non-negative ints — `%` and `/` match exactly.
//  * `time` is the engine global (NMFullscreen alias, normalized 0..1). The
//    WGSL bound it at @binding(6); we read the engine `time` directly.
//  * floor(speedA)/floor(speedB): speedA/speedB are int uniforms in the
//    definition but the WGSL declares them f32 and applies floor(); we keep
//    them as `float` uniforms and floor() literally to match the WGSL.
//  * normalize(-gradient + 0.000001): WGSL uses 0.000001 (vec3 splat). The
//    GLSL uses 1e-6 (identical value). Reproduced as float3(1e-6,1e-6,1e-6).
//  * sqrt(3.0), 0.57735027, 0.45/0.42/0.5/0.35/0.12/0.6/0.4/0.3/0.25 magic
//    constants copied literally from the WGSL.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
int   loopAOffset;   // globals.loopAOffset  default 40  (shape type A)
int   loopBOffset;   // globals.loopBOffset  default 30  (shape type B)
float loopAScale;    // globals.loopAScale   default 1
float loopBScale;    // globals.loopBScale   default 1
float speedA;        // globals.speedA       default 1   (WGSL f32, floor()ed)
float speedB;        // globals.speedB       default 1   (WGSL f32, floor()ed)
int   volumeSize;    // globals.volumeSize   default 64  (atlas slice edge)
// colorMode (globals.colorMode) is declared in the definition but UNUSED by
// the precompute shader (the scalar field is always written mono r=g=b=d).
int   colorMode;     // globals.colorMode    default 0   (declared, unused here)

static const float SH3_PI  = 3.14159265359;
static const float SH3_TAU = 6.28318530718;

// ---- Verbatim helpers (ported from precompute.wgsl) -------------------------

float sh3_map_range(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (outMax - outMin) * (value - inMin) / (inMax - inMin);
}

float sh3_periodicFunction(float p)
{
    float x = SH3_TAU * p;
    return sh3_map_range(sin(x), -1.0, 1.0, 0.0, 1.0);
}

// ============================================
// 3D Polyhedral SDF Functions
// ============================================

// Tetrahedron (4 faces, 4 vertices)
float sh3_tetrahedronSDF(float3 p)
{
    float s = 0.5;
    return (max(abs(p.x + p.y) - p.z, abs(p.x - p.y) + p.z) - s) / sqrt(3.0);
}

// Cube / Hexahedron (6 faces, 8 vertices)
float sh3_cubeSDF(float3 p)
{
    float3 d = abs(p) - float3(0.45, 0.45, 0.45);
    return length(max(d, float3(0.0, 0.0, 0.0))) + min(max(d.x, max(d.y, d.z)), 0.0);
}

// Octahedron (8 faces, 6 vertices)
float sh3_octahedronSDF(float3 p)
{
    float3 ap = abs(p);
    float s = 0.5;
    return (ap.x + ap.y + ap.z - s) * 0.57735027;
}

// Dodecahedron (12 pentagonal faces, 20 vertices)
float sh3_dodecahedronSDF(float3 p)
{
    float3 ap = abs(p);
    float phi = (1.0 + sqrt(5.0)) * 0.5;  // Golden ratio

    float3 n1 = normalize(float3(1.0, phi, 0.0));
    float3 n2 = normalize(float3(0.0, 1.0, phi));
    float3 n3 = normalize(float3(phi, 0.0, 1.0));

    float d = 0.0;
    d = max(d, dot(ap, n1));
    d = max(d, dot(ap, n2));
    d = max(d, dot(ap, n3));
    d = max(d, ap.x);
    d = max(d, ap.y);
    d = max(d, ap.z);

    return d - 0.45;
}

// Icosahedron (20 triangular faces, 12 vertices)
float sh3_icosahedronSDF(float3 p)
{
    float3 ap = abs(p);
    float phi = (1.0 + sqrt(5.0)) * 0.5;

    float3 n1 = normalize(float3(phi, 1.0, 0.0));
    float3 n2 = normalize(float3(1.0, 0.0, phi));
    float3 n3 = normalize(float3(0.0, phi, 1.0));

    float d = 0.0;
    d = max(d, dot(ap, n1));
    d = max(d, dot(ap, n2));
    d = max(d, dot(ap, n3));
    d = max(d, dot(ap, normalize(float3(1.0, 1.0, 1.0))));

    return d - 0.42;
}

// ============================================
// Other 3D Primitive SDFs
// ============================================

float sh3_sphereSDF(float3 p)
{
    return length(p) - 0.5;
}

float sh3_torusSDF(float3 p)
{
    float2 t = float2(0.35, 0.12);
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}

float sh3_cylinderSDF(float3 p)
{
    float2 d = abs(float2(length(p.xz), p.y)) - float2(0.35, 0.45);
    return min(max(d.x, d.y), 0.0) + length(max(d, float2(0.0, 0.0)));
}

float sh3_coneSDF(float3 p)
{
    float h = 0.6;
    float r = 0.4;
    float2 c = normalize(float2(h, r));
    float q = length(p.xz);
    return max(dot(c.xy, float2(q, p.y)), -p.y - h * 0.5);
}

float sh3_capsuleSDF(float3 p)
{
    float h = 0.3;
    float r = 0.25;
    float3 pp = p;
    pp.y = pp.y - clamp(pp.y, -h, h);
    return length(pp) - r;
}

// Get SDF value for shape type
float sh3_shapeSDF(float3 p, int shapeType)
{
    // Platonic Solids
    if (shapeType == 10) { return sh3_tetrahedronSDF(p); }
    if (shapeType == 20) { return sh3_cubeSDF(p); }
    if (shapeType == 30) { return sh3_octahedronSDF(p); }
    if (shapeType == 40) { return sh3_dodecahedronSDF(p); }
    if (shapeType == 50) { return sh3_icosahedronSDF(p); }

    // Other Primitives
    if (shapeType == 100) { return sh3_sphereSDF(p); }
    if (shapeType == 110) { return sh3_torusSDF(p); }
    if (shapeType == 120) { return sh3_cylinderSDF(p); }
    if (shapeType == 130) { return sh3_coneSDF(p); }
    if (shapeType == 140) { return sh3_capsuleSDF(p); }

    return sh3_sphereSDF(p);
}

// Get SDF-based offset for a position (p in [0,1]^3)
float sh3_offset3D(float3 p, float freq, int loopOffset)
{
    // Center at origin: [0,1] -> [-0.5, 0.5]
    float3 cp = p - float3(0.5, 0.5, 0.5);

    // SDF is negative inside, positive outside
    // Convert to offset: invert and scale by freq for periodic shells
    float sdf = sh3_shapeSDF(cp, loopOffset);
    return (0.5 - sdf) * freq;
}

// Compute full output value for a position (for gradient computation)
float sh3_computeValue(float3 p, float lf1, float lf2)
{
    float offset1 = sh3_offset3D(p, lf1, loopAOffset);
    float offset2 = sh3_offset3D(p, lf2, loopBOffset);

    // Drive periodic function from SDF offset + time * speed
    // Speed is integer so time (0-1 loop) stays seamless
    float t1 = offset1 + time * floor(speedA);
    float t2 = offset2 + time * floor(speedB);

    float a = sh3_periodicFunction(t1);
    float b = sh3_periodicFunction(t2);

    return (a + b) * 0.5;
}

// =============================================================================
// PASS: precompute — atlas volume-write (frag_precompute), MRT drawBuffers:2
// =============================================================================
struct Shape3dPrecomputeOut
{
    float4 color  : SV_Target0;   // -> volumeCache (scalar field rgba16f)
    float4 geoOut : SV_Target1;   // -> geoBuffer (xyz=normal*0.5+0.5, w=d)
};

Shape3dPrecomputeOut frag_precompute(NMVaryings i)
{
    // Convert 2D fragment position to 3D volume coordinates.
    // position.xy (top-left, +0.5 centered) -> NM_FragCoord(i).
    float2 fragCoord = NM_FragCoord(i);

    int volSize = volumeSize;
    float volSizeF = (float)volSize;
    int x = (int)fragCoord.x;
    int yAtlas = (int)fragCoord.y;
    int y = yAtlas % volSize;
    int z = yAtlas / volSize;

    // Normalize to [0, 1]
    float3 p = float3((float)x, (float)y, (float)z) / (volSizeF - 1.0);

    // Calculate frequencies from scale parameters
    float lf1 = sh3_map_range(loopAScale, 1.0, 100.0, 6.0, 1.0);
    float lf2 = sh3_map_range(loopBScale, 1.0, 100.0, 6.0, 1.0);

    // Compute value at this position
    float d = sh3_computeValue(p, lf1, lf2);

    // Compute analytical gradient using finite differences
    float eps = 1.0 / volSizeF;
    float dx = sh3_computeValue(p + float3(eps, 0.0, 0.0), lf1, lf2);
    float dy = sh3_computeValue(p + float3(0.0, eps, 0.0), lf1, lf2);
    float dz = sh3_computeValue(p + float3(0.0, 0.0, eps), lf1, lf2);

    float3 gradient = float3(dx - d, dy - d, dz - d) / eps;
    float3 normal = normalize(-gradient + float3(0.000001, 0.000001, 0.000001));

    Shape3dPrecomputeOut o;
    o.color  = float4(d, d, d, 1.0);
    o.geoOut = float4(normal * 0.5 + 0.5, d);
    return o;
}

#endif // NM_EFFECT_SHAPE3D_INCLUDED
