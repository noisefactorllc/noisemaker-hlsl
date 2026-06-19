Shader "Noisemaker/synth/shape"
{
    // synth/shape (func: "shape") — interference patterns from geometric shapes.
    // Single render pass (progName "shape"). Generator: no texture inputs.
    //
    // Runtime binds per-effect params via MaterialPropertyBlock by their reference
    // `uniform` names (loopAScale, loopBScale, speedA, speedB, seed, wrap) plus the
    // two compile-time selectors modeled as int uniforms (LOOP_A_OFFSET,
    // LOOP_B_OFFSET). Engine globals (_NM_*) are bound by NMPipeline.
    //
    // The Properties block is for inspector convenience only; the runtime path
    // uses MaterialPropertyBlock, not material serialization.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // ---- Pass: "shape" (progName from definition.js passes[0].program) -----
        Pass
        {
            Name "shape"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_shape
            #pragma target 4.5
            // Full 32-bit float parity — never downgrade to half/min16float.
            #pragma exclude_renderers gles
            #include "Shape.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
