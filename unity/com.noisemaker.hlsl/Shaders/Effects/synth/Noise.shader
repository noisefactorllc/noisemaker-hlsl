Shader "Noisemaker/synth/noise"
{
    // synth/noise (VNoise) — value noise with multiple interpolation types.
    // Single render pass (program "noise"). Generator: no texture inputs.
    //
    // The runtime binds per-effect params via MaterialPropertyBlock by the
    // names declared in Noise.hlsl (scaleX, scaleY, seed, loopScale, speed,
    // octaves, ridges, wrap, colorMode, NOISE_TYPE, LOOP_OFFSET). The Properties
    // block below is for inspector visibility only.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }

        // Render-pass program "noise" (definition.js passes[0].program).
        Pass
        {
            Name "noise"

            ZWrite Off
            ZTest Always
            Cull Off
            Blend Off

            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_noise
            #pragma target 4.5
            // Full 32-bit float parity — never downgrade to half/min16float.
            #pragma exclude_renderers gles

            #include "Noise.hlsl"

            // outputs.fragColor -> outputTex (the effect's outgoing surface).
            float4 frag_noise(NMVaryings i) : SV_Target
            {
                // WGSL passes `position.xy` (raw frag coord) to offset(); st adds
                // tileOffset separately. NM_FragCoord = pixel-centered frag coord.
                float2 fragCoord = NM_FragCoord(i);
                return nm_noise(fragCoord, _NM_TileOffset.xy, _NM_FullResolution.xy);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
