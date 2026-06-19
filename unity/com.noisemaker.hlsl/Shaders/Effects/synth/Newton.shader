Shader "Noisemaker/synth/newton"
{
    // synth/newton — Newton fractal explorer. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Newton.hlsl. The Properties block is for inspector convenience only.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass "newton" (definition.js passes[0].program = "newton")
        Pass
        {
            Name "newton"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; df64 is bit-sensitive.
            #pragma exclude_renderers gles
            #include "Newton.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_newton(globalCoord, resolution, fullResolution);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
