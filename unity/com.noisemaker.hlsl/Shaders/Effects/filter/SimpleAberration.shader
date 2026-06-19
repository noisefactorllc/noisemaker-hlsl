Shader "Noisemaker/filter/simpleAberration"
{
    // filter/simpleAberration — chromatic aberration effect.
    // Single render pass (program "chromaticAberration"). One uniform: displacement.
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "chromaticAberration" (definition.js passes[0].program)
        Pass
        {
            Name "chromaticAberration"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "SimpleAberration.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // Follows the GLSL golden: globalPixel = gl_FragCoord + tileOffset
                // (= NM_GlobalCoord), divided by fullResolution to globalUV inside,
                // with the per-channel Y flip the GLSL applies. texSize from the
                // input dimensions (textureSize(inputTex,0)).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                return nm_simpleAberration(inputTex, sampler_inputTex,
                                           NM_GlobalCoord(i), float2(tw, th));
            }
            ENDHLSL
        }
    }
    Fallback Off
}
