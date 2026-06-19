Shader "Noisemaker/synth/spectrum"
{
    // synth/spectrum — audio spectrum analyzer generator. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Spectrum.hlsl (lineColor, lineThickness, gain, audioSpectrum[0..31]).
    // The Properties block is for inspector convenience only.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "spectrum" (definition.js passes[0].program)
        Pass
        {
            Name "spectrum"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles
            #include "Spectrum.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // fragCoord = pixel-space top-left +0.5 centered.
                return nm_spectrum(NM_FragCoord(i));
            }
            ENDHLSL
        }
    }
    Fallback Off
}
