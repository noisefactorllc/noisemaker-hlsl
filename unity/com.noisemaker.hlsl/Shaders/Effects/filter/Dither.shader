Shader "Noisemaker/filter/dither"
{
    // filter/dither — ordered dithering with classic patterns and palettes.
    // Single render pass. Properties are for the inspector only; the runtime binds
    // these via MaterialPropertyBlock by their reference uniform names
    // (ditherType/matrixScale/threshold/palette/levels/mixAmount) and binds the
    // input surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "dither" (definition.js passes[0].program)
        Pass
        {
            Name "dither"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Dither.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let texSize = vec2<f32>(textureDimensions(inputTex));
                //   let uv = pos.xy / texSize;
                // Divide the raw frag coord (NM_FragCoord, top-left +0.5) by the
                // INPUT TEXTURE's own size (not fullResolution). No flip.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);

                float2 pixelCoord = NM_FragCoord(i);
                float2 uv = pixelCoord / texSize;

                float4 color = inputTex.Sample(sampler_inputTex, uv);
                return nm_dither(color, pixelCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
