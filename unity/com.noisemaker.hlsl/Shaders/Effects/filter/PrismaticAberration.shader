Shader "Noisemaker/filter/prismaticAberration"
{
    // filter/prismaticAberration — chromatic fringing with HSV edge boost and passthrough mix.
    // Single render pass (program "prismaticAberration"). Input: inputTex.
    // Runtime binds per-effect parameters via MaterialPropertyBlock by their uniform names.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "prismaticAberration" (definition.js passes[0].program)
        Pass
        {
            Name "prismaticAberration"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "PrismaticAberration.hlsl"

            // Input surface. Bilinear, clamp-to-edge, linear (non-sRGB) to match WebGL2/WebGPU (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: fragCoord = builtin(position).xy (top-left, +0.5 centered)
                // NM_FragCoord(i) is the HLSL analog.
                return nm_prismaticAberration(inputTex, sampler_inputTex, NM_FragCoord(i));
            }
            ENDHLSL
        }
    }
    Fallback Off
}
