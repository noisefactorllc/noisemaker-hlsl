Shader "Noisemaker/synth/scope"
{
    // synth/scope — audio waveform oscilloscope generator. Single render pass.
    // Runtime binds params via MaterialPropertyBlock: lineColor, lineThickness,
    // gain, audioWaveform[32] (packed float4 array). Properties block is for
    // inspector convenience only; live values come from MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "scope" (definition.js passes[0].program)
        Pass
        {
            Name "scope"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float.
            #pragma exclude_renderers gles
            #include "Scope.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // fragCoord: pixel-centered top-left coords (+0.5 centered).
                // Scope uses NM_FragCoord (not NM_GlobalCoord) because WGSL
                // uses position.xy directly (no tileOffset). // TODO(verify): confirm
                // whether tileOffset should be added for tiled renders; WGSL has none.
                float2 fragCoord = NM_FragCoord(i);
                return nm_scope(fragCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
