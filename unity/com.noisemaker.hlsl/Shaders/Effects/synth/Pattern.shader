Shader "Noisemaker/synth/pattern"
{
    // synth/pattern — geometric pattern generator. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Pattern.hlsl (patternType, scale, thickness, smoothness, rotation, skew,
    // animation, speed, fgColor, bgColor). Properties block is for inspector
    // convenience only; values come from MaterialPropertyBlock at render time.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "pattern" (definition.js passes[0].program)
        Pass
        {
            Name "pattern"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles
            #include "Pattern.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL main() receives position.xy (pixel-centered, top-left).
                // NM_FragCoord returns uv * resolution = pixel center coords.
                // Pass as fragCoord; tileOffset excluded because WGSL uses plain
                // position.xy (no tile offset in the original effect).
                // TODO(verify): if tiling is required, switch to NM_GlobalCoord(i).
                return nm_pattern(NM_FragCoord(i));
            }
            ENDHLSL
        }
    }
    Fallback Off
}
