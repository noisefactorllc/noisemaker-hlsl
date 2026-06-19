Shader "Noisemaker/filter/lowPoly"
{
    // filter/lowPoly — Voronoi-based low-polygon art style. Single render pass.
    // Properties are for the inspector only; the runtime binds these via
    // MaterialPropertyBlock by their reference uniform names
    // (scale/seed/mode/edgeStrength/edgeColor/alpha/speed) and binds the input
    // surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "lowPoly" (definition.js passes[0].program)
        Pass
        {
            Name "lowPoly"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "LowPoly.hlsl"

            // Input surface. Sampler must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL:
                //   let texSize  = vec2<f32>(textureDimensions(inputTex));
                //   let uv       = pos.xy / texSize;
                //   let globalUV = (pos.xy + tileOffset) / fullResolution;
                // pos = @builtin(position) (top-left, +0.5). NM_FragCoord(i) is the
                // HLSL analog; NM_GlobalCoord(i) adds tileOffset.
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize  = float2(tw, th);
                float2 uv       = NM_FragCoord(i) / texSize;
                float2 globalUV = NM_GlobalCoord(i) / fullResolution;

                return nm_lowpoly(inputTex, sampler_inputTex, texSize, uv, globalUV);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
