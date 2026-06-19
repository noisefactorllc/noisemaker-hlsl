Shader "Noisemaker/synth/julia"
{
    // synth/julia — Julia set explorer, single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Julia.hlsl. The Properties block is for inspector convenience only.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "julia" (definition.js passes[0].program)
        Pass
        {
            Name "julia"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles
            #include "Julia.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: pos.xy + tileOffset, fullResolution used for coord space
                float2 fragCoord = NM_FragCoord(i);
                return nm_julia(fragCoord, tileOffset, fullResolution, time);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
