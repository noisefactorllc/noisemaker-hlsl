Shader "Noisemaker/synth/testPattern"
{
    // synth/testPattern — test patterns for debugging and calibration. Single
    // render pass. Runtime binds params via MaterialPropertyBlock by the names
    // declared in TestPattern.hlsl (gridSize, pattern). The Properties block
    // below is for inspector convenience only; values come from the
    // MaterialPropertyBlock at render time.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "testPattern" (definition.js passes[0].program)
        Pass
        {
            Name "testPattern"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion.
            #pragma exclude_renderers gles
            #include "TestPattern.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // globalCoord = fragCoord + tileOffset (top-left, +0.5 centered).
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_testPattern(globalCoord, resolution, fullResolution);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
