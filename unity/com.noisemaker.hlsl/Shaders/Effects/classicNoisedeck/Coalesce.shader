Shader "Noisemaker/classicNoisedeck/coalesce"
{
    // classicNoisedeck/coalesce — blend two inputs with selectable blend mode,
    // optional refractive cloaking, and cross-fade. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by their reference uniform
    // names and binds input surfaces to inputTex / tex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "coalesce" (definition.js passes[0].program)
        Pass
        {
            Name "coalesce"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles

            // Input surfaces — bilinear, clamp-to-edge, LINEAR (non-sRGB) to
            // match the WebGL2/WebGPU RGBA path (H7). Declared BEFORE #include so
            // Coalesce.hlsl's extern declarations resolve to these.
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            #include "Coalesce.hlsl"

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL main():
                //   let dims = vec2<f32>(textureDimensions(inputTex, 0));
                //   var st   = position.xy / dims;
                // NM_FragCoord(i) is the HLSL analog of position.xy (top-left, +0.5).
                uint dw, dh;
                inputTex.GetDimensions(dw, dh);
                float2 dims = float2(dw, dh);
                float2 st   = NM_FragCoord(i) / dims;

                return nm_coalesce(st);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
