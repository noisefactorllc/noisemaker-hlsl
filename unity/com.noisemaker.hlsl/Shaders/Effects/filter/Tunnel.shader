Shader "Noisemaker/filter/tunnel"
{
    // filter/tunnel — perspective tunnel with shape options, antialias, center vignette.
    // Single render pass. Inspector-only Properties; the runtime binds these via
    // MaterialPropertyBlock using the exact uniform names from definition.js.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "tunnel" (definition.js passes[0].program)
        Pass
        {
            Name "tunnel"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_tunnel
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Tunnel.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
