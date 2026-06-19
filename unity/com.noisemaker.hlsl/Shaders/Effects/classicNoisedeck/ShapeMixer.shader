Shader "Noisemaker/classicNoisedeck/shapeMixer"
{
    // classicNoisedeck/shapeMixer — two-input shape mixer. Generates a procedural
    // shape field, animates it, blends the two inputs' luminance under a selectable
    // blend mode, and colorizes via palette modes. Single render pass.
    // Properties are inspector-only; the runtime binds params via
    // MaterialPropertyBlock by their reference uniform names and binds the two
    // input surfaces to inputTex / tex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "shapeMixer" (definition.js passes[0].program)
        Pass
        {
            Name "shapeMixer"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ShapeMixer.hlsl"

            // Input surfaces. Samplers must be bilinear, clamp-to-edge, LINEAR
            // (non-sRGB) to match the WebGL2/WebGPU RGBA path (H7).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;
            Texture2D    tex;
            SamplerState sampler_tex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: var st = fragCoord.xy / u.resolution; (the CURRENT render
                // target resolution). NM_FragCoord(i) = uv*resolution = pixel-
                // centered (+0.5) target coords, the position.xy analog. The SAME
                // st samples BOTH textures. tileOffset is NOT added (WGSL omits it).
                float2 st = NM_FragCoord(i) / resolution;

                float4 color1 = inputTex.Sample(sampler_inputTex, st);
                float4 color2 = tex.Sample(sampler_tex, st);

                return nm_shapeMixer(color1, color2, st);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
