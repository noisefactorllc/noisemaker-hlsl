Shader "Noisemaker/synth/gabor"
{
    // synth/gabor — anisotropic bandlimited Gabor noise generator. Single
    // render pass. Runtime binds params via MaterialPropertyBlock by the names
    // declared in Gabor.hlsl (scale, orientation, bandwidth, isotropy, density,
    // octaves, speed, seed). The Properties block below is for inspector
    // convenience only; values come from the MaterialPropertyBlock at render time.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "gabor" (definition.js passes[0].program)
        Pass
        {
            Name "gabor"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "Gabor.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_gabor(globalCoord, fullResolution, time);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
