Shader "Noisemaker/mixer/shadow"
{
    // mixer/shadow — cast a shadow or glow from one input onto another.
    // Single render pass ("shadow"). The runtime binds params via
    // MaterialPropertyBlock by their reference uniform names and binds the two
    // input surfaces to inputTex / tex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "shadow" (definition.js passes[0].program)
        Pass
        {
            Name "shadow"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Shadow.hlsl"

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            // Note: tex is renamed tex_ in the .hlsl to avoid keyword collision;
            // Unity binds by the Property name "tex" -> SamplerState sampler_tex.
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let dims = vec2<f32>(textureDimensions(inputTex, 0));
                //   let uv   = position.xy / dims;
                // pos = @builtin(position) (top-left, +0.5); NM_FragCoord(i) is the
                // HLSL analog. tileOffset is NOT added (the WGSL does not use it).
                return nm_shadow(
                    inputTex, sampler_inputTex,
                    tex,      sampler_tex,
                    NM_FragCoord(i));
            }
            ENDHLSL
        }
    }
    Fallback Off
}
