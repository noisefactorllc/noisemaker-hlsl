Shader "Noisemaker/filter/flipMirror"
{
    // filter/flipMirror — Flip and mirror image transformations.
    // Single render pass ("flipMirror"). One int uniform: flipMode.
    // Samples inputTex at a warped UV derived from the INPUT texture's own
    // dimensions (matching the WGSL textureDimensions path, not fullResolution).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass name matches definition.js passes[0].program = "flipMirror"
        Pass
        {
            Name "flipMirror"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "FlipMirror.hlsl"

            // Input surface. Sampler: bilinear, clamp-to-edge, LINEAR (non-sRGB).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
                //        var uv = pos.xy / texSize;
                // pos = @builtin(position), top-left, +0.5 centered.
                // NM_FragCoord(i) is the HLSL analog.
                // Divide by the INPUT TEXTURE's own size (not fullResolution).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);

                return nm_flipMirror(inputTex, sampler_inputTex, texSize, NM_FragCoord(i));
            }
            ENDHLSL
        }
    }
    Fallback Off
}
