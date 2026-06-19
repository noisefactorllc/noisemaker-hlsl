Shader "Noisemaker/classicNoisedeck/bitEffects"
{
    // classicNoisedeck/bitEffects — bit field / bit mask generator. Single
    // render pass (definition.js passes[0].program == "bitEffects"). No texture
    // inputs (generator). Runtime binds params via MaterialPropertyBlock by the
    // bare reference uniform names declared in BitEffects.hlsl (speed, n, scale,
    // ...; matching definition.js globals[*].uniform; and the
    // formerly-compile-time defines as int uniforms MODE/FORMULA/COLOR_SCHEME/
    // INTERP/MASK_FORMULA/MASK_COLOR_SCHEME). The Properties block is inspector
    // convenience only; values come from the MaterialPropertyBlock at render time.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "bitEffects" (definition.js passes[0].program)
        Pass
        {
            Name "bitEffects"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "BitEffects.hlsl"

            // No texture inputs (generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_bitEffects(globalCoord, resolution, fullResolution, time);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
