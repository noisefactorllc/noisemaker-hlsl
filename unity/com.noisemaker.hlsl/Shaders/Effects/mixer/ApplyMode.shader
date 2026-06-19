Shader "Noisemaker/mixer/applyMode"
{
    // mixer/applyMode — apply brightness, hue, or saturation from source B
    // (tex) onto source A (inputTex), cross-faded with `mixAmt`.
    // Single render pass. Properties are for the inspector only; the runtime
    // binds params via MaterialPropertyBlock under the reference uniform names
    // (mode / mixAmt) and binds the two input surfaces to inputTex / tex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "applyMode" (definition.js passes[0].program)
        Pass
        {
            Name "applyMode"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ApplyMode.hlsl"

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let dims = vec2<f32>(textureDimensions(inputTex, 0));
                //   var st   = position.xy / dims;
                //   color1 = textureSample(inputTex, samp, st);
                //   color2 = textureSample(tex,      samp, st);
                // Same st (derived from inputTex's own size) samples BOTH
                // textures. tileOffset is NOT added (the WGSL does not add it).
                uint dw, dh;
                inputTex.GetDimensions(dw, dh);
                float2 dims = float2(dw, dh);
                float2 st = NM_FragCoord(i) / dims;

                float4 color1 = inputTex.Sample(sampler_inputTex, st);
                float4 color2 = tex.Sample(sampler_tex, st);

                return nm_applyMode(color1, color2);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
