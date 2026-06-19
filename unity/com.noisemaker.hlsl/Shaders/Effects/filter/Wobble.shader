Shader "Noisemaker/filter/wobble"
{
    // filter/wobble — offsets the entire frame using noise-driven jitter.
    // wrap: 0 mirror, 1 repeat, 2 clamp (emulated in-shader). Single render pass.
    // Properties are for the inspector only; the runtime binds these via
    // MaterialPropertyBlock by their reference uniform names (speed/range/wrap)
    // and binds the input surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "wobble" (definition.js passes[0].program)
        Pass
        {
            Name "wobble"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Wobble.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7). repeat/mirror
            // wrap is emulated in applyWrap, so the HW sampler stays clamp.
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL samples `in.uv + offset` (top-left fullscreen-pass UV),
                // NOT fragCoord/texSize. Pass i.uv straight through.
                return nm_wobble(inputTex, sampler_inputTex, i.uv);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
