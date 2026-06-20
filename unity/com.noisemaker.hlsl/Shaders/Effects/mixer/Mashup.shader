Shader "Noisemaker/mixer/mashup"
{
    // mixer/mashup — Luminance-band router ("mega mixer"). ONE render pass: posterize
    // the control input (source) by luminance into `layers` equal bands and route each
    // band to its layerN_tex source (darkest -> layer0). `smoothness` feathers the band
    // boundaries (0 = hard posterize); unwired bands (layerN_active == 0) fall back to
    // the control input. Starter effect — output size from the engine `resolution`.
    //
    // Multi-input mixer (source + layer0_tex..layer7_tex), modeled on synth/remap. The
    // runtime binds each input surface and the per-layer colorModeUniform active flags
    // (layerN_active) by name via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "mashup" (definition.js passes[0].program)
        Pass
        {
            Name "mashup"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_mashup
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Mashup.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
