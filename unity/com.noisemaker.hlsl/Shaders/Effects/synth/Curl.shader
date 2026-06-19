Shader "Noisemaker/synth/curl"
{
    // synth/curl — 3D curl noise generator. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Curl.hlsl (scale, seed, speed, intensity, octaves, ridges, outputMode).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "curl" (definition.js passes[0].program)
        Pass
        {
            Name "curl"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles
            #include "Curl.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // NM_GlobalCoord = fragCoord (top-left, +0.5) — tileOffset is
                // added INSIDE nm_curl() to match the WGSL exactly.
                float2 fragCoord = NM_FragCoord(i);
                return nm_curl(fragCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
