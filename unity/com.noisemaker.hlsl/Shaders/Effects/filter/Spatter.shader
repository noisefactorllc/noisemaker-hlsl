Shader "Noisemaker/filter/spatter"
{
    // filter/spatter — multi-layer procedural paint spatter over the input.
    // Single render pass. Properties are for the inspector only; the runtime binds
    // these via MaterialPropertyBlock by their reference uniform names
    // (color/density/alpha/seed) and binds the input surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "spatter" (definition.js passes[0].program)
        Pass
        {
            Name "spatter"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Spatter.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL (lines 181-182):
                //   let uv = (pos.xy + uniforms.tileOffset) / uniforms.fullResolution;
                //   let base = textureSample(inputTex, inputSampler, uv);
                // NM_GlobalCoord(i) = NM_FragCoord(i) + tileOffset (top-left, +0.5).
                float2 uv = NM_GlobalCoord(i) / fullResolution;
                float4 base = inputTex.Sample(sampler_inputTex, uv);
                return nm_spatter(base, uv);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
