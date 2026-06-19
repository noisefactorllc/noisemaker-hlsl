Shader "Noisemaker/mixer/distortion"
{
    // mixer/distortion — displace, refract, or reflect between two surfaces
    // using Sobel-derived normals. Single render pass.
    // The runtime binds params via MaterialPropertyBlock (mode / mapSource /
    // intensity / wrap / smoothing / aberration / antialias) and binds the two
    // input surfaces to inputTex / tex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "distortion" (definition.js passes[0].program)
        Pass
        {
            Name "distortion"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            #include "Distortion.hlsl"

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let dims = vec2f(textureDimensions(inputTex, 0));
                //   let uv   = position.xy / dims;
                //   let texelSize = 1.0 / dims;
                // NM_FragCoord(i) is the HLSL analog of WGSL position.xy.
                // tileOffset is NOT added (the WGSL does not add it).
                uint dw, dh;
                inputTex.GetDimensions(dw, dh);
                float2 dims = float2(dw, dh);
                float2 uv = NM_FragCoord(i) / dims;
                float2 texelSize = 1.0 / dims;

                return nm_distortion(uv, texelSize);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
