Shader "Noisemaker/synth/remap"
{
    // synth/remap — Polygon-zone router. Single render pass.
    // Up to 8 zone textures (zone0_tex..zone7_tex) are sampled inside their
    // respective polygons. Zones with unwired textures (active=0) are skipped.
    // Runtime binds params via MaterialPropertyBlock by the uniform names
    // declared in Remap.hlsl.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "remap" (definition.js passes[0].program)
        Pass
        {
            Name "remap"

            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles

            #include "Remap.hlsl"

            float4 frag(NMVaryings i) : SV_Target
            {
                // NM_FragCoord: pixel-centered tile-local coord (top-left, +0.5).
                float2 fragCoord = NM_FragCoord(i);
                return nm_remap(fragCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
