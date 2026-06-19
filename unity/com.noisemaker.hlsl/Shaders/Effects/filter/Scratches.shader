Shader "Noisemaker/filter/scratches"
{
    // filter/scratches — CPU-baked film-scratch overlay max-blended over input.
    //
    // Single render pass (progName "scratchesBlend"). The overlayTex is generated
    // by the C# runtime's asyncInit equivalent (traceWorms CPU path) and supplied
    // as a Texture2D. Both textures are loaded with Texture2D.Load (integer pixel
    // coords), mirroring WGSL textureLoad — no sampler is needed for the blend.
    //
    // The runtime supplies:
    //   inputTex   — main input surface
    //   overlayTex — CPU-baked scratch mask (RGBA8 or ARGBHalf)
    //   alpha      — float uniform [0,1], default 0.75
    //   (density, seed are CPU-only; they drive asyncInit, not GPU)



    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass 0 — progName "scratchesBlend" (definition.js passes[0].program)
        Pass
        {
            Name "scratchesBlend"
            HLSLPROGRAM
            #pragma vertex   NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles

            #include "Scratches.hlsl"

            // The .hlsl already declares inputTex, overlayTex, and alpha.
            // No samplers declared: both textures are accessed via .Load() which
            // requires no SamplerState (textureLoad in WGSL is also sampler-free).

            float4 frag(NMVaryings i) : SV_Target
            {
                return NMFrag_scratchesBlend(i);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
