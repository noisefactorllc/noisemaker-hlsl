Shader "Noisemaker/filter/edge"
{
    // filter/edge — edge detection with multiple kernels, sizes, and blend modes.
    // Single render pass "edge". All per-effect params bound via MaterialPropertyBlock.
    // Source: shaders/effects/filter/edge/wgsl/edge.wgsl


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "edge" (definition.js passes[0].program)
        Pass
        {
            Name "edge"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Edge.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                return nm_edge_frag(inputTex, sampler_inputTex, NM_FragCoord(i));
            }
            ENDHLSL
        }
    }
    Fallback Off
}
