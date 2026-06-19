Shader "Noisemaker/filter/reverb"
{
    // filter/reverb — visual reverb/echo: blends input with multiple 2x-scaled
    // samples of itself, accumulating with halved weights each octave.
    // Single render pass (program "reverb", definition.js passes[0]).
    // The runtime binds the input surface to inputTex via MaterialPropertyBlock.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "reverb" (definition.js passes[0].program)
        Pass
        {
            Name "reverb"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Reverb.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let dimsU = textureDimensions(inputTex, 0);
                //   let dims  = vec2<f32>(f32(dimsU.x), f32(dimsU.y));
                //   let uv    = pos.xy / dims;
                // pos = @builtin(position) (top-left, +0.5). NM_FragCoord(i) is the
                // HLSL analog. Divide by the INPUT TEXTURE's own size (not fullRes).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 dims = float2((float)tw, (float)th);
                float2 uv   = NM_FragCoord(i) / dims;

                float4 original = inputTex.Sample(sampler_inputTex, uv);
                return nm_reverb(original, uv, inputTex, sampler_inputTex);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
