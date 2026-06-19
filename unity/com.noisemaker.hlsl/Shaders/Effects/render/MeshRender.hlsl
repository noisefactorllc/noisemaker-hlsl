#ifndef NM_EFFECT_MESHRENDER_INCLUDED
#define NM_EFFECT_MESHRENDER_INCLUDED

// =============================================================================
// MeshRender.hlsl — render/meshRender (func: "meshRender") — rasterize an OBJ
// mesh with Blinn-Phong lighting.  3D / RENDER tier (geometry rasterization).
//
// Ported PIXEL-IDENTICALLY from the canonical WGSL sources (top-left clip space,
// D3D-oriented exactly like Unity HLSL; golden rule #1):
//   wgsl/clear.wgsl    progName "clear"   (frag_clear)             fullscreen
//   wgsl/render.wgsl   progName "render"  (vert_render/frag_render) geometry
//
// PASS ORDER per frame (2) — from definition.js passes[]:
//   1. clear  (program "clear",  fullscreen)  fill output with bg color (premult).
//   2. render (program "render", drawMode:"triangles", count:'input') rasterize
//             mesh triangles.  The VS reads vertex attributes from the mesh data
//             textures by SV_VertexID (DrawProcedural over vertex indices) and
//             projects to clip space; the FS does Blinn-Phong + rim + gamma.
//
// MESH SURFACES (per reference 04 §8 / §10.3) — the global mesh0 surface is a
// TRIPLET of 256x256 rgba32f textures uploaded CPU-side by render/meshLoader
// (uploadMeshData / loadOBJ); NOT ping-ponged, static data:
//   global_mesh0_positions (rgba32f, 256x256) — xyz = world position, w = valid
//   global_mesh0_normals   (rgba32f, 256x256) — xyz = normal,         w unused
//   (global_mesh0_uvs exists in the surface record but this effect reads only
//    positions + normals; the VS derives its own uv from the texel coordinate.)
// count:'input' resolves to width*height of meshPositions = 256*256 = 65536
// vertices (the runtime issues DrawProcedural(Triangles, count)). Each group of
// 3 consecutive vertices forms one triangle; meshLoader lays out indexed faces
// as expanded vertex runs in the textures.
//
// DEPTH / CULL (reference webgl2 backend triangles branch): the render pass runs
// with DEPTH_TEST (gl.LESS), depthMask on, CULL_FACE BACK, frontFace CCW, and
// CLEARS the depth buffer for the pass. The .shader mirrors this: ZWrite On,
// ZTest LEqual, Cull Back, Clear depth on the geometry pass. clipPos.y is flipped
// in the VS exactly as the WGSL does (D3D/WebGPU top-left clip); orthographic
// depth maps Z in [-10,10] to NDC [0,1].
//
// NOTE: 3D / multi-pass / geometry effect → ships as a runtime-rendered Texture2D.
// NO Shader Graph Custom Function wrapper is provided (per PORTING-GUIDE: geometry
// & multi-pass excluded). The C# runtime drives the 2 passes in order, rebinding
// inputs/outputs and setting named uniforms (and the mesh-data textures) via
// MaterialPropertyBlock by reference name.
//
// PORTING-GUIDE / parity notes:
//  * WGSL textureLoad(meshPositions, vec2i(x,y), 0) → meshPositions.Load(int3(x,y,0))
//    — integer texel fetch, point, no filtering, in the VERTEX stage (SM4.5). rgba32f.
//  * WGSL textureDimensions(meshPositions,0) → meshPositions.GetDimensions(w,h).
//  * mat3x3 rotations ported verbatim (column-major construction; HLSL float3x3
//    rows below are written so that mul(rotation, v) reproduces the WGSL
//    `rotation * vector` exactly — see vert_render).
//  * deg2rad literal 3.14159265 / 180.0 reproduced verbatim.
//  * gamma: pow(color, 1.0/2.2) per component (WGSL pow(color, vec3(1.0/2.2))).
//  * Wireframe: WGSL render.wgsl uses a SIMPLIFIED flat-color wireframe (no
//    derivative edge detection / discard — that exists only in the GLSL render.frag).
//    We port the WGSL (canonical) behavior: wireframe==1 → flat u.meshColor.
//  * No NMCore helpers used; this effect has no PRNG. nm_mod / fmod NOT used.
// =============================================================================

#include "../../Include/NMFullscreen.hlsl"

// ---- Mesh data textures (runtime rebinds per definition.js inputs{}) --------
// clear:  (no inputs)
// render: meshPositions, meshNormals (Load, in the VERTEX stage); inputTex is
//         declared by the definition for chainability but is NOT sampled by the
//         WGSL/GLSL render shader (kept for parity of the binding list).
Texture2D meshPositions;  SamplerState sampler_meshPositions;
Texture2D meshNormals;    SamplerState sampler_meshNormals;
Texture2D inputTex;       SamplerState sampler_inputTex;

// ---- Per-effect named uniforms (match definition.js globals[*].uniform) -----
// clear pass:
float3 bgColor;           // globals.bgColor          default (0.1, 0.1, 0.15)
float  bgAlpha;           // globals.bgAlpha          default 1.0

// render pass — mesh model transforms:
float  meshScale;         // globals.scale            default 1.0   (uniform meshScale)
float  offsetX;           // globals.offsetX          default 0.0   (uniform offsetX)  WGSL u.offsetX
float  offsetY;           // globals.offsetY          default 0.0   (uniform offsetY)
float  offsetZ;           // globals.offsetZ          default 0.0   (uniform offsetZ)
// render pass — view/camera transforms (rotations in DEGREES):
float  rotateX;           // globals.rotateX          default 0
float  rotateY;           // globals.rotateY          default 0
float  rotateZ;           // globals.rotateZ          default 0
float  viewScale;         // globals.viewScale        default 1.0
float  posX;              // globals.posX             default 0.0
float  posY;              // globals.posY             default 0.0
// render pass — lighting / material:
float3 lightDirection;    // globals.lightDirection   default (0.5, 0.7, 0.5)
float3 diffuseColor;      // globals.diffuseColor     default (1, 1, 1)
float  diffuseIntensity;  // globals.diffuseIntensity default 0.7
float3 specularColor;     // globals.specularColor    default (1, 1, 1)
float  specularIntensity; // globals.specularIntensity default 0.3
float  shininess;         // globals.shininess        default 32.0
float3 ambientColor;      // globals.ambientColor     default (0.1, 0.1, 0.1)
float  rimIntensity;      // globals.rimIntensity     default 0.15
float  rimPower;          // globals.rimPower         default 3.0
float3 meshColor;         // globals.meshColor        default (0.8, 0.8, 0.8)
int    wireframe;         // globals.wireframe        default 0 (0 solid / 1 wireframe)

// =============================================================================
// Verbatim rotation matrices (this effect's own; ported from render.wgsl).
//
// The WGSL mat3x3<f32> constructor takes COLUMN vectors:
//   rotationX = mat3x3( (1,0,0), (0,c,-s), (0,s,c) )  → columns
// and the shader evaluates `rotation * vector` (column-major matrix · vector).
// HLSL `mul(M, v)` treats M as row-major (M's rows dotted with v). To reproduce
// the WGSL math exactly we build the HLSL float3x3 from the WGSL ROWS, i.e. the
// transpose of the column list. For rotationX the WGSL matrix as
// row·column entries is:
//   row0 = (1, 0, 0)
//   row1 = (0, c, s)      // col1.y=c, col2.y=-s  → element (1,2) = -s ... see below
// To avoid any ambiguity we write each HLSL matrix so that
// mul(M_hlsl, v) == M_wgsl * v elementwise. Derivation (WGSL columns c0,c1,c2):
//   (M*v).x = c0.x*v.x + c1.x*v.y + c2.x*v.z
//   (M*v).y = c0.y*v.x + c1.y*v.y + c2.y*v.z
//   (M*v).z = c0.z*v.x + c1.z*v.y + c2.z*v.z
// So HLSL row r = (c0[r], c1[r], c2[r]).
// =============================================================================
float3x3 mr_rotationX(float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    // WGSL cols: c0=(1,0,0) c1=(0,c,-s) c2=(0,s,c)
    // rows: (c0.x,c1.x,c2.x)=(1,0,0); (c0.y,c1.y,c2.y)=(0,c,s); (c0.z,c1.z,c2.z)=(0,-s,c)
    return float3x3(
        1.0, 0.0, 0.0,
        0.0,   c,   s,
        0.0,  -s,   c
    );
}

float3x3 mr_rotationY(float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    // WGSL cols: c0=(c,0,-s) c1=(0,1,0) c2=(s,0,c)
    // rows: (c,0,s); (0,1,0); (-s,0,c)
    return float3x3(
          c, 0.0,   s,
        0.0, 1.0, 0.0,
         -s, 0.0,   c
    );
}

float3x3 mr_rotationZ(float angle)
{
    float c = cos(angle);
    float s = sin(angle);
    // WGSL cols: c0=(c,-s,0) c1=(s,c,0) c2=(0,0,1)
    // rows: (c,s,0); (-s,c,0); (0,0,1)
    return float3x3(
          c,   s, 0.0,
         -s,   c, 0.0,
        0.0, 0.0, 1.0
    );
}

// =============================================================================
// PASS 1: clear — fill output with background color (premultiplied alpha).
// Pass name "clear".  WGSL: return vec4(u.bgColor * u.bgAlpha, u.bgAlpha).
// =============================================================================
float4 frag_clear(NMVaryings i) : SV_Target
{
    return float4(bgColor * bgAlpha, bgAlpha);
}

// =============================================================================
// PASS 2: render — rasterize mesh triangles (vert_render / frag_render).
//
// Custom vertex stage: one vertex per SV_VertexID (count = meshPositions
// width*height = 65536, DrawProcedural(Triangles, count)). Reads mesh attributes
// in the VERTEX stage via Texture2D.Load (SM4.5). Ported verbatim from
// render.wgsl vs_main (including the WebGPU Y flip and ortho depth mapping).
// =============================================================================
struct MeshRenderVaryings
{
    float4 positionCS : SV_POSITION;
    float3 normal     : TEXCOORD0;
    float2 uv         : TEXCOORD1;
    float3 worldPos   : TEXCOORD2;
};

MeshRenderVaryings vert_render(uint vertexID : SV_VertexID)
{
    MeshRenderVaryings o;

    // Texture dimensions (== 256x256 mesh data atlas). WGSL: textureDimensions(meshPositions,0).
    uint tw, th;
    meshPositions.GetDimensions(tw, th);
    int texWidth = (int)tw;

    // Texel coordinate from vertex ID.  WGSL: x = id % texWidth, y = id / texWidth.
    int vertexIDi = (int)vertexID;
    int x = vertexIDi % texWidth;
    int y = vertexIDi / texWidth;

    // Read vertex data (rgba32f, point fetch in the VS).
    float4 posData    = meshPositions.Load(int3(int2(x, y), 0));
    float4 normalData = meshNormals.Load(int3(int2(x, y), 0));

    float3 position = posData.xyz;
    float3 normal   = normalData.xyz;

    // Apply mesh model transforms (scale then offset).
    position = position * meshScale;
    position.x = position.x + offsetX;
    position.y = position.y + offsetY;
    position.z = position.z + offsetZ;

    // Build rotation matrix (uniforms are in degrees).
    float deg2rad = 3.14159265 / 180.0;
    // WGSL: rotation = rotationZ(rz) * rotationY(ry) * rotationX(rx)
    // (matrix product; same multiply order in HLSL via mul of float3x3).
    float3x3 rotation = mul(mr_rotationZ(rotateZ * deg2rad),
                        mul(mr_rotationY(rotateY * deg2rad),
                            mr_rotationX(rotateX * deg2rad)));

    // Transform.  WGSL: rotation * position (col-major) == mul(rotation_hlsl, v).
    float3 rotatedPos    = mul(rotation, position);
    float3 rotatedNormal = mul(rotation, normal);

    // Apply camera translation.
    rotatedPos.x = rotatedPos.x + posX;
    rotatedPos.y = rotatedPos.y + posY;

    // Orthographic projection with scale.
    float2 clipPos = rotatedPos.xy * viewScale;
    clipPos.x = clipPos.x / aspectRatio;

    // Flip Y (WGSL flips for WebGPU top-left clip; Unity/D3D clip is also
    // top-left, so we preserve the WGSL flip verbatim for canonical parity).
    clipPos.y = -clipPos.y;

    // Orthographic depth: map Z to NDC range [0, 1] for the depth buffer.
    float nearZ = -10.0;
    float farZ  = 10.0;
    float ndcZ  = (rotatedPos.z - nearZ) / (farZ - nearZ);  // → [0, 1]

    o.positionCS = float4(clipPos, ndcZ, 1.0);
    o.normal     = rotatedNormal;
    o.uv         = float2((float)x / (float)texWidth, (float)y / (float)((int)th));
    o.worldPos   = rotatedPos;
    return o;
}

float4 frag_render(MeshRenderVaryings i) : SV_Target
{
    // Normalize inputs.
    float3 normal   = normalize(i.normal);
    float3 lightDir = normalize(lightDirection);

    // View direction (camera looking down -Z in orthographic).
    float3 viewDir = float3(0.0, 0.0, 1.0);

    // Ambient lighting.
    float3 ambient = ambientColor * meshColor;

    // Diffuse lighting (Lambertian).
    float diffuseFactor = max(dot(normal, lightDir), 0.0);
    float3 diffuse = diffuseColor * diffuseFactor * meshColor * diffuseIntensity;

    // Specular lighting (Blinn-Phong).
    float3 halfDir = normalize(lightDir + viewDir);
    float specAngle = max(dot(halfDir, normal), 0.0);
    float specularFactor = pow(specAngle, shininess);
    float3 specular = specularColor * specularFactor * specularIntensity;

    // Fresnel rim lighting.
    float rim = pow(1.0 - max(dot(normal, viewDir), 0.0), rimPower);
    float3 rimLight = float3(rim, rim, rim) * rimIntensity;

    // Combine lighting.
    float3 color = ambient + diffuse + specular + rimLight;

    // Wireframe mode (WGSL canonical: simplified flat color, no edge detection).
    if (wireframe == 1)
    {
        color = meshColor;
    }

    // Gamma correction.  WGSL: pow(color, vec3(1.0 / 2.2)).
    color = pow(color, float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));

    return float4(color, 1.0);
}

#endif // NM_EFFECT_MESHRENDER_INCLUDED
