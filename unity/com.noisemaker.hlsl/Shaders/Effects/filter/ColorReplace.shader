Shader "Noisemaker/filter/colorReplace"
{
    // filter/colorReplace — match pixels near targetColor and remap RGB/alpha.
    // Single render pass (definition.js passes[0].program "colorReplace").
    // Runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "colorReplace" (definition.js passes[0].program)
        Pass
        {
            Name "colorReplace"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ColorReplace.hlsl"

            // Input surface. Sampler: bilinear, clamp-to-edge, LINEAR (non-sRGB)
            // to match the WebGPU textureSampleLevel path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: size = max(textureDimensions(inputTex, 0), vec2<u32>(1,1))
                //        st   = position.xy / vec2<f32>(size)
                // NM_FragCoord(i) is top-left, +0.5 centered — exact analog of
                // WGSL @builtin(position).xy. Divide by the INPUT TEXTURE's own
                // size, not fullResolution.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(max(tw, 1u), max(th, 1u));
                float2 uv = NM_FragCoord(i) / texSize;

                float4 src = inputTex.SampleLevel(sampler_inputTex, uv, 0.0);
                return nm_colorReplace(src);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
