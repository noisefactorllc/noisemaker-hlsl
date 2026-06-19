Shader "Noisemaker/filter/corrupt"
{
    // filter/corrupt — scanline-based data corruption (pixel sort, byte shift,
    // bit manipulation, channel separation, melt, scatter). Single render pass.
    // Properties are for the inspector only; the runtime binds these via
    // MaterialPropertyBlock by their reference uniform names and binds the input
    // surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "corrupt" (definition.js passes[0].program)
        Pass
        {
            Name "corrupt"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Corrupt.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: fragCoord = pos.xy (@builtin(position), top-left, +0.5).
                // NM_FragCoord(i) is the HLSL analog. resolution / uv computed in
                // nm_corrupt from the INPUT TEXTURE's own dimensions (not fullRes).
                return nm_corrupt(inputTex, sampler_inputTex, NM_FragCoord(i));
            }
            ENDHLSL
        }
    }
    Fallback Off
}
