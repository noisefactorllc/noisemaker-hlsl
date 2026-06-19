Shader "Noisemaker/classicNoisedeck/fractal"
{
    // classicNoisedeck/fractal — fractal pattern generator. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Fractal.hlsl (type, zoomAmt, rotation, speed, offsetX, offsetY, centerX,
    // centerY, mode, iterations, colorMode, paletteMode, cyclePalette,
    // rotatePalette, repeatPalette, paletteOffset, hueRange, paletteAmp, levels,
    // paletteFreq, bgAlpha, palettePhase, cutoff, bgColor, symmetry).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "fractal" (definition.js passes[0].program)
        Pass
        {
            Name "fractal"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles
            #include "Fractal.hlsl"

            // No texture inputs (generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_fractal(globalCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
