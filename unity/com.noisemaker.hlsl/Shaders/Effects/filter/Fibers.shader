Shader "Noisemaker/filter/fibers"
{
    // filter/fibers — alpha-composite a CPU-rendered fiber overlay over the input.
    // Single render pass ("fibersBlend"). The CPU asyncInit traces worms and fills
    // overlayTex; this pass composites it over inputTex weighted by `alpha`.
    //
    // Properties are for the inspector only; the runtime binds these via
    // MaterialPropertyBlock by their reference uniform names (alpha) and binds
    // inputTex / overlayTex from the effect's texture slots.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "fibersBlend" (definition.js passes[0].program)
        Pass
        {
            Name "fibersBlend"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Fibers.hlsl"

            // WGSL uses textureLoad (integer coord), not textureSample — no sampler
            // needed for Load. Declare Texture2D only (SamplerState unused but
            // harmless to omit for Load-only access).
            Texture2D inputTex;
            Texture2D overlayTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let coord = vec2<i32>(i32(pos.x), i32(pos.y));
                // pos = @builtin(position) top-left, fractional +0.5.
                // Truncate to integer pixel (matches i32 cast in WGSL).
                // TODO(verify): NM_FragCoord returns uv*resolution (+0.5 centered);
                // for Load we want the integer pixel index. (int)NM_FragCoord(i)
                // truncates to the pixel, matching i32(pos.x), i32(pos.y) in WGSL.
                int2 coord = (int2)NM_FragCoord(i);

                // textureLoad / texelFetch — pixel-exact, no bilinear filtering.
                float4 base    = inputTex.Load(int3(coord, 0));
                float4 overlay = overlayTex.Load(int3(coord, 0));

                return nm_fibers_blend(base, overlay);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
