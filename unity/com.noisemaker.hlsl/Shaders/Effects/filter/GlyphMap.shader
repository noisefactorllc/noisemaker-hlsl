Shader "Noisemaker/filter/glyphMap"
{
    // filter/glyphMap — convert the input image to ASCII/glyph art using
    // hardcoded 5x7 glyph bitmaps ordered by density. Single render pass.
    // Properties are for the inspector only; the runtime binds these via
    // MaterialPropertyBlock by their reference uniform names
    // (cellSize/seed/colorMode) and binds the input surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "glyphMap" (definition.js passes[0].program)
        Pass
        {
            Name "glyphMap"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "GlyphMap.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let texSize = vec2<f32>(textureDimensions(inputTex));
                //   var pixelCoord = pos.xy;   // @builtin(position), top-left +0.5
                // Sample coord divides by the INPUT TEXTURE's own dimensions (not
                // fullResolution). NM_FragCoord(i) is the HLSL pos.xy analog.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 pos = NM_FragCoord(i);
                return nm_glyphMap(pos, texSize, inputTex, sampler_inputTex);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
