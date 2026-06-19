Shader "Noisemaker/filter/spookyTicker"
{
    // filter/spookyTicker — Scrolling pseudo-text ticker overlay.
    // Single render pass (program "spookyTicker").
    // Inputs:  inputTex (source surface bound by runtime via MaterialPropertyBlock)
    // Globals: speed, alpha (float); rows, seed (int)

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass: progName "spookyTicker" (definition.js passes[0].program)
        Pass
        {
            Name "spookyTicker"
            HLSLPROGRAM
            #pragma vertex   NMVertFullscreen
            #pragma fragment frag
            #pragma target   4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "SpookyTicker.hlsl"

            float4 frag(NMVaryings i) : SV_Target
            {
                return NMFrag_spookyTicker(i);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
