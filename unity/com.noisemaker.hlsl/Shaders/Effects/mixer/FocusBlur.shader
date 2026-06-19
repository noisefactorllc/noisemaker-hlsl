Shader "Noisemaker/mixer/focusBlur"
{
    // mixer/focusBlur — focus blur (depth of field) using luminance depth map.
    // Uses inputTex + tex as two mixer inputs; single render pass.
    // The runtime binds params via MaterialPropertyBlock by their reference
    // uniform names (depthSource / focalDistance / aperture / sampleBias) and
    // binds the two input surfaces to inputTex / tex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "focusBlur" (definition.js passes[0].program)
        Pass
        {
            Name "focusBlur"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "FocusBlur.hlsl"

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let dims = vec2f(textureDimensions(inputTex, 0));
                //   let uv   = position.xy / dims;
                // pos = @builtin(position) (top-left, +0.5); NM_FragCoord(i) is the
                // HLSL analog. uv derived from inputTex's own size used for all samples.
                uint dw, dh;
                inputTex.GetDimensions(dw, dh);
                float2 dims = float2(dw, dh);
                float2 uv = NM_FragCoord(i) / dims;

                return nm_focusBlur(uv, dims,
                    inputTex, sampler_inputTex,
                    tex, sampler_tex);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
