Shader "Noisemaker/synth/mandala"
{
    // synth/mandala — N-fold symmetric mandala generator. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Mandala.hlsl (scale, rotation, thickness, smoothness, symmetry, bindu,
    // shape, layers, layerSpacing, twist, shapeGrowth, fgColor, bgColor,
    // animation, speed, pulseDepth). The Properties block is for inspector
    // convenience only; values come from the MaterialPropertyBlock at render time.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "mandala" (definition.js passes[0].program)
        Pass
        {
            Name "mandala"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles
            #include "Mandala.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // fragCoord = pixel-centered top-left coordinate (matches WGSL position.xy).
                float2 fragCoord = NM_FragCoord(i);
                return nm_mandala(fragCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
