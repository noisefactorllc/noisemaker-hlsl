Shader "Noisemaker/filter/translate"
{
    // filter/translate — Translate image in X and Y with wrap mode.
    // Single render pass. Per-effect params: x (float), y (float), wrap (int).
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "translate" (definition.js passes[0].program)
        Pass
        {
            Name "translate"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles

            #include "Translate.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            // NOTE: Texture2D and SamplerState are declared inside Translate.hlsl;
            // they are visible here because this HLSLPROGRAM block includes it.

            float4 frag(NMVaryings i) : SV_Target
            {
                return NMFrag_translate(i);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
