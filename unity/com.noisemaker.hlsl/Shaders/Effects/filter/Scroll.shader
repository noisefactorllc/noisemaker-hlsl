Shader "Noisemaker/filter/scroll"
{
    // filter/scroll — scrolling offset animation with mirror/repeat/clamp wrap.
    // Single render pass ("scroll"). Ported pixel-identically from WGSL.
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "scroll" (definition.js passes[0].program)
        Pass
        {
            Name "scroll"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Scroll.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge (wrap is applied
            // manually in the shader), LINEAR (non-sRGB) to match the reference (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: position.xy (top-left, +0.5 centered). NM_FragCoord is the
                // HLSL analog. st is computed from fragCoord / resolution inside nm_scroll.
                return nm_scroll(NM_FragCoord(i), inputTex, sampler_inputTex);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
