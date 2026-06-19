Shader "Noisemaker/classicNoisedeck/shapes"
{
    // classicNoisedeck/shapes — interference patterns from geometric shapes.
    // Generator (no texture inputs). Single render pass "shapes".
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Shapes.hlsl (LOOP_A_OFFSET, LOOP_B_OFFSET, loopAScale, loopBScale, speedA,
    // speedB, seed, wrap, paletteMode, paletteOffset, paletteAmp, paletteFreq,
    // palettePhase, cyclePalette, rotatePalette, repeatPalette). The Properties
    // block is inspector convenience only; values come from the MPB at render time.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "shapes" (definition.js passes[0].program)
        Pass
        {
            Name "shapes"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "Shapes.hlsl"

            // No texture inputs (generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_shapes(globalCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
