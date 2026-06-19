Shader "Noisemaker/synth/modPattern"
{
    // synth/modPattern — interference patterns from modulo operations.
    // Single render pass, no texture inputs (synth generator).
    // Runtime binds params via MaterialPropertyBlock using the uniform names
    // declared in ModPattern.hlsl (shape1/scale1/repeat1, shape2/scale2/repeat2,
    // shape3/scale3/repeat3, blend, smoothing, animMode, speed).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass for program "modPattern" (definition.js passes[0].program)
        Pass
        {
            Name "modPattern"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles
            #include "ModPattern.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // fragCoord = pixel center (+0.5), top-left origin (matches WGSL position.xy).
                // NM_FragCoord does NOT add tileOffset; NM_GlobalCoord does.
                // WGSL uses position.xy (local fragment coord), not global coord.
                // modPattern normalizes by resolution, not fullResolution, so we
                // pass the local fragment coord here. // TODO(verify) tiling behavior
                float2 fragCoord = NM_FragCoord(i);
                return nm_modPattern(fragCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
