Shader "Noisemaker/filter/normalMap"
{
    // filter/normalMap — Normal map generation via 3×3 Sobel filter.
    // Single render pass, program name "normalMap" (definition.js passes[0].program).
    // No per-effect parameters (definition.js globals: {}).
    // Uses Texture2D.Load (integer fetch) to match the WGSL textureLoad path.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "normalMap" (definition.js passes[0].program)
        Pass
        {
            Name "normalMap"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "NormalMap.hlsl"

            // Input surface. Accessed via .Load (integer texel fetch), matching the
            // WGSL textureLoad path. SamplerState declared for completeness but the
            // core function does not sample — it loads by integer coordinate.
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // NM_FragCoord(i) gives top-left pixel-centre coords (WGSL gid.xy
                // analog). Truncate to int2 for the Load path.
                int2 fragCoord = (int2)NM_FragCoord(i);
                return nm_normalMap(inputTex, fragCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
