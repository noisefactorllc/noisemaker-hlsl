#ifndef NM_VOLUME_ATLAS_INCLUDED
#define NM_VOLUME_ATLAS_INCLUDED

// =============================================================================
// NMVolumeAtlas.hlsl — the 3D VOLUME ATLAS convention shared by every synth3d /
// filter3d WRITER and every render3d / renderLit3d RAYMARCH consumer.
//
// There is NO hardware Tex3D in this pipeline. A "3D volume" is a 2D atlas
// RenderTexture of  volumeSize x volumeSize^2  (default 64 x 4096 == 64 stacked
// slices of 64x64), rgba16f LINEAR. Both writers and readers address it as a 2D
// texture by INTEGER texel fetch (point sampling). This file is the single source
// of truth for the voxel <-> atlas (u,v) mapping; ported shaders MUST use these
// helpers so the C# runtime (TextureStore atlas RT + NMRenderBackend viewport
// override) and the shaders agree bit-for-bit.
//
// RUNTIME CONTRACT (must hold for these helpers to address correctly):
//   * TextureStore creates the volume RT as a 2D RenderTexture sized
//     volumeSize x volumeSize^2 (NOT a UnityEngine Tex3D). See TextureStore.cs
//     "VOLUME ATLAS CONVENTION".
//   * For a WRITE pass, NMRenderBackend sets the cmd viewport to the atlas dims
//     AND overrides _NM_Resolution to (volumeSize, volumeSize^2), so that
//     NM_FragCoord (= uv * _NM_Resolution) yields integer ATLAS pixel coords.
//     (Pass.ViewportWidth/Height carry these; see Pass.cs / Expander viewport.)
//   * For a READ/raymarch pass, _NM_Resolution is the SCREEN size; the volume is
//     sampled only via NM_AtlasLoad below (never via NM_FragCoord).
//
// MAPPING (reproduced EXACTLY from the reference GLSL atlasTexel, golden rule #1
//   shaders/effects/render/render3d/glsl/render3d.glsl):
//       atlasTexel(voxel.xyz, volSize) = int2( voxel.x, voxel.y + voxel.z * volSize )
//   i.e. slice z occupies atlas rows [z*volSize, (z+1)*volSize); within a slice the
//   row is voxel.y and the column is voxel.x. WRITE direction inverts it:
//       voxel = ( px.x, px.y % volSize, px.y / volSize )   (integer % and /)
// =============================================================================

// voxel (x,y,z) -> atlas pixel (u,v). volSize = volumeSize (int uniform).
int2 NM_VoxelToAtlas(int3 voxel, int volSize)
{
    return int2(voxel.x, voxel.y + voxel.z * volSize);
}

// atlas pixel (u,v) -> voxel (x,y,z). Used by WRITE shaders to recover the voxel
// they are rasterizing from the integer NM_FragCoord. Integer % and / match the
// reference (y % volSize, y / volSize).
int3 NM_AtlasToVoxel(int2 px, int volSize)
{
    return int3(px.x, px.y % volSize, px.y / volSize);
}

// Point-fetch one voxel from the atlas (clamped to [0, volSize-1]^3). Mirrors the
// reference texelFetch(volumeCache, atlasTexel(clamp(voxel)), 0). `atlas` is the
// Texture2D bound under the pass's sampler name (e.g. `volumeCache`).
float4 NM_AtlasLoad(Texture2D atlas, int3 voxel, int volSize)
{
    int3 c = clamp(voxel, int3(0, 0, 0), int3(volSize - 1, volSize - 1, volSize - 1));
    return atlas.Load(int3(NM_VoxelToAtlas(c, volSize), 0));
}

// Manual trilinear sample at a normalized volume coord uvw in [0,1]^3 (8-corner
// fetch + lerp). Mirrors the reference trilinear path (render3d.glsl getFieldSmooth /
// renderLit3d): texelPos = uvw*(volSize-1); i0 = floor; i1 = min(i0+1, volSize-1).
// HW 3D bilinear is unavailable on a 2D atlas, so filtering is ALWAYS manual.
float4 NM_AtlasSampleTrilinear(Texture2D atlas, float3 uvw, int volSize)
{
    float vsF = (float)volSize;
    float3 texelPos = saturate(uvw) * (vsF - 1.0);
    int3 i0 = (int3)floor(texelPos);
    i0 = clamp(i0, int3(0, 0, 0), int3(volSize - 1, volSize - 1, volSize - 1));
    int3 i1 = min(i0 + 1, int3(volSize - 1, volSize - 1, volSize - 1));
    float3 f = texelPos - (float3)i0;

    float4 c000 = atlas.Load(int3(NM_VoxelToAtlas(int3(i0.x, i0.y, i0.z), volSize), 0));
    float4 c100 = atlas.Load(int3(NM_VoxelToAtlas(int3(i1.x, i0.y, i0.z), volSize), 0));
    float4 c010 = atlas.Load(int3(NM_VoxelToAtlas(int3(i0.x, i1.y, i0.z), volSize), 0));
    float4 c110 = atlas.Load(int3(NM_VoxelToAtlas(int3(i1.x, i1.y, i0.z), volSize), 0));
    float4 c001 = atlas.Load(int3(NM_VoxelToAtlas(int3(i0.x, i0.y, i1.z), volSize), 0));
    float4 c101 = atlas.Load(int3(NM_VoxelToAtlas(int3(i1.x, i0.y, i1.z), volSize), 0));
    float4 c011 = atlas.Load(int3(NM_VoxelToAtlas(int3(i0.x, i1.y, i1.z), volSize), 0));
    float4 c111 = atlas.Load(int3(NM_VoxelToAtlas(int3(i1.x, i1.y, i1.z), volSize), 0));

    float4 x00 = lerp(c000, c100, f.x);
    float4 x10 = lerp(c010, c110, f.x);
    float4 x01 = lerp(c001, c101, f.x);
    float4 x11 = lerp(c011, c111, f.x);
    float4 y0 = lerp(x00, x10, f.y);
    float4 y1 = lerp(x01, x11, f.y);
    return lerp(y0, y1, f.z);
    // TODO(verify): confirm lerp/floor ULP vs the reference mix()/floor across the
    // parity harness; the corner indices and weight order match the GLSL exactly.
}

#endif // NM_VOLUME_ATLAS_INCLUDED
