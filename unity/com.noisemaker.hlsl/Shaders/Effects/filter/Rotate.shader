Shader "Noisemaker/filter/rotate"
{
    // filter/rotate — rotates the input texture by a given angle with aspect-correct
    // centering and configurable wrap (mirror/repeat/clamp).
    // Single render pass (program "rot"). Ported from WGSL rot.wgsl.
    // The runtime binds uniforms via MaterialPropertyBlock using the reference
    // uniform names (rotation, wrap, speed) and binds the input surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "rot" (definition.js passes[0].program)
        Pass
        {
            Name "rot"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Rotate.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
                //        var uv = pos.xy / texSize;
                // NM_FragCoord(i) is the HLSL analog of pos.xy (top-left, +0.5).
                // Divide by the INPUT TEXTURE's own size (not fullResolution).
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);
                float2 uv = NM_FragCoord(i) / texSize;

                float2 rotUV = nm_rotate_uv(uv, texSize);
                return inputTex.Sample(sampler_inputTex, rotUV);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
