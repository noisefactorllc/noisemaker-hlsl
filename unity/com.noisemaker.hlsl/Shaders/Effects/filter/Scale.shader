Shader "Noisemaker/filter/scale"
{
    // filter/scale — UV scale transform around a center point with wrap modes.
    // Single render pass. Per-effect parameters: scaleX, scaleY, centerX, centerY, wrap.
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "scale" (definition.js passes[0].program)
        Pass
        {
            Name "scale"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Scale.hlsl"

            // Input surface. Sampler: bilinear, clamp-to-edge, LINEAR (non-sRGB)
            // to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: var st = position.xy / resolution;
                // NM_FragCoord(i) = top-left pixel center (+0.5).
                // Divide by resolution.xy (the render target size), matching the WGSL.
                return nm_scale(NM_FragCoord(i), resolution, inputTex, sampler_inputTex);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
