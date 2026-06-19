Shader "Noisemaker/synth/gradient"
{
    // synth/gradient — multi-color gradient generator. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Gradient.hlsl (rotation, gradientType, repeat, colorCount, speed, seed,
    // color1..color4). The Properties block below is for inspector convenience
    // only; values come from the MaterialPropertyBlock at render time.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "gradient" (definition.js passes[0].program)
        Pass
        {
            Name "gradient"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "Gradient.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_gradient(globalCoord, resolution, fullResolution, time);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
