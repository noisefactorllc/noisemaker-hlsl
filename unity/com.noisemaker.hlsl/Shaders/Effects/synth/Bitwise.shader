Shader "Noisemaker/synth/bitwise"
{
    // synth/bitwise — bitwise operation pattern generator. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the uniform names declared
    // in Bitwise.hlsl (operation, mask, scale, rotation, offsetX, offsetY, seed,
    // speed, colorMode, colorOffset). The Properties block is for inspector
    // convenience only; values come from the MaterialPropertyBlock at render time.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "bitwise" (definition.js passes[0].program)
        Pass
        {
            Name "bitwise"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles
            #include "Bitwise.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                // Matches WGSL: position.xy + tileOffset.
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_bitwise(globalCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
