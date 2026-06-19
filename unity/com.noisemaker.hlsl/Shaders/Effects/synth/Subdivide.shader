Shader "Noisemaker/synth/subdivide"
{
    // synth/subdivide — recursive grid subdivision with shapes. Single render
    // pass. The runtime binds params via MaterialPropertyBlock by the names
    // declared in Subdivide.hlsl (mode, depth, density, seed, fill, outline,
    // inputMix, speed, wrap) and binds the optional input surface to inputTex.
    // Properties are for inspector convenience only.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "subdivide" (definition.js passes[0].program)
        Pass
        {
            Name "subdivide"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (PCG is bit-sensitive).
            #pragma exclude_renderers gles
            #include "Subdivide.hlsl"

            // Input surface (sampled only when inputMix > 0). Sampler must be
            // bilinear, clamp-to-edge, LINEAR (non-sRGB) to match the WebGL2/
            // WebGPU RGBA path (H7). Wrap modes are applied in-shader on the coord.
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: st = pos.xy / u.data[0].xy (the RENDER resolution), no
                // tileOffset. NM_FragCoord(i) is the top-left, +0.5 analog of
                // @builtin(position).
                float2 fragCoord = NM_FragCoord(i);
                return nm_subdivide(fragCoord, resolution, time,
                                    inputTex, sampler_inputTex);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
