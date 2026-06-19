Shader "Noisemaker/filter/skew"
{
    // filter/skew — skew and rotate transform.
    // Single render pass. Input: inputTex. Uniforms: skewAmt, rotation, wrap.
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "skew" (definition.js passes[0].program)
        Pass
        {
            Name "skew"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Skew.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: pos.xy / vec2<f32>(textureDimensions(inputTex))
                // NM_FragCoord(i) = pixel-center coord in render target space.
                // The INPUT TEXTURE shares the same dimensions as the render target
                // in the standard fullscreen pipeline, so this is correct.
                return nm_skew(NM_FragCoord(i), inputTex, sampler_inputTex);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
