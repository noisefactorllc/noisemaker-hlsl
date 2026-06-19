Shader "Noisemaker/synth/perlin"
{
    // synth/perlin — Perlin-like gradient noise with optional domain warp.
    // Single render pass (program "perlin"). Inputs: none (pure generator).
    // Output: RGBA noise (mono or rgb per colorMode).
    // Runtime binds params via MaterialPropertyBlock by their reference uniform
    // name; the Properties block is for inspector convenience only.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        // render-type pass: no inputs, no blending, fullscreen triangle.
        Pass
        {
            Name "perlin"
            ZWrite Off ZTest Always Cull Off Blend Off

            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float only (PCG / hash3 bit-sensitive).
            #pragma exclude_renderers gles gles3

            #include "../../Include/NMFullscreen.hlsl"
            #include "Perlin.hlsl"

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL main(): st = (position.xy + tileOffset) / fullResolution,
                // then st.x *= aspect. aspect = fullResolution.x/fullResolution.y.
                // (H13 note: this effect divides st by fullResolution — BOTH axes
                //  via the vector — NOT height-only; the aspect multiply on x is
                //  what reconciles the axes. Reproduced literally from WGSL.)
                float2 globalCoord = NM_GlobalCoord(i);
                float  aspect      = _NM_FullResolution.x / _NM_FullResolution.y;

                return nm_perlin(globalCoord, _NM_FullResolution.xy, aspect, _NM_Time);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
