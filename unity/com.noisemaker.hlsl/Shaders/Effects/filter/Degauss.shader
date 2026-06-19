Shader "Noisemaker/filter/degauss"
{
    // filter/degauss — CRT degauss effect: per-channel simplex-noise lens warp
    // with singularity mask and directional rotation.
    //
    // Single render pass ("degauss", name="main"). Uses manual bilinear sampling
    // via Texture2D.Load (integer texel fetch), mirroring WGSL textureLoad —
    // NO SamplerState is needed for the effect math.
    //
    // Per-effect uniforms set by the runtime via MaterialPropertyBlock:
    //   float displacement  (default 0.0625, range [0, 0.25])
    //   float direction     (default 0.0,    range [-180, 180])
    //   int   seed          (default 1,      range [1, 100])
    //   float speed         (default 1.0,    range [0, 2])


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass name matches definition.js passes[0].name = "main",
        // program = "degauss".
        Pass
        {
            Name "main"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Degauss.hlsl"

            float4 frag(NMVaryings i) : SV_Target
            {
                // Obtain input texture dimensions for pixel-based addressing.
                // This matches WGSL: width = params.dims0.x, height = params.dims0.y
                // (the texture's own size, not fullResolution).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float width_f  = (float)tw;
                float height_f = (float)th;

                // Integer pixel coords matching WGSL gid.xy.
                // NM_FragCoord(i) = uv * resolution (pixel centre, top-left origin).
                // floor gives the integer pixel index.
                float2 fc  = NM_FragCoord(i);
                uint2  px  = uint2((uint)fc.x, (uint)fc.y);

                return nm_degauss(px, width_f, height_f);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
