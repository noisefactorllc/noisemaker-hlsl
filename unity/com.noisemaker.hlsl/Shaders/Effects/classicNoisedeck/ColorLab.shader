Shader "Noisemaker/classicNoisedeck/colorLab"
{
    // classicNoisedeck/colorLab — color manipulation lab. Single-input filter,
    // single render pass (program "colorLab"). Posterize, dither, color-mode
    // conversion (mono/linearRgb/srgbDefault/oklab/palette), then hue/sat/
    // brightness/contrast grading.
    //
    // Properties are for the inspector only; the runtime binds these via
    // MaterialPropertyBlock by their reference uniform names and binds the input
    // surface to inputTex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "colorLab" (definition.js passes[0].program)
        Pass
        {
            Name "colorLab"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ColorLab.hlsl"

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL main():
                //   var uv = fragCoord.xy / u.resolution;
                //   var color = textureSample(inputTex, samp, uv);
                // pos = @builtin(position) (top-left, +0.5). NM_FragCoord(i) is the
                // HLSL analog. Divide by `resolution` (current target) exactly as the
                // WGSL does (NOT the input tex dims, NOT fullResolution). The WGSL
                // dither/random/bayer terms use the same raw fragCoord (no tileOffset).
                float2 fragCoord = NM_FragCoord(i);
                float2 uv = fragCoord / resolution;

                float4 color = inputTex.Sample(sampler_inputTex, uv);
                return nm_colorLab(color, fragCoord);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
