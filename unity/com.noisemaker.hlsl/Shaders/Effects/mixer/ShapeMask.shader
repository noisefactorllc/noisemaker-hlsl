Shader "Noisemaker/mixer/shapeMask"
{
    // mixer/shapeMask — composite two inputs inside/outside a geometric SDF shape.
    // Single render pass (program "shapeMask"). Runtime binds params by their
    // reference uniform names via MaterialPropertyBlock; input surfaces bound to
    // inputTex / tex.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "shapeMask" (definition.js passes[0].program)
        Pass
        {
            Name "shapeMask"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "ShapeMask.hlsl"

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
                //   let st   = position.xy / dims;
                //   colorA = textureSample(inputTex, samp, st);
                //   colorB = textureSample(tex, samp, st);
                // The SAME st (from inputTex's own dims) samples BOTH textures.
                // tileOffset is NOT added to the sample UV (WGSL does not add it).
                uint dw, dh;
                inputTex.GetDimensions(dw, dh);
                float2 dims = float2(dw, dh);
                float2 st = NM_FragCoord(i) / dims;

                float4 colorA = inputTex.Sample(sampler_inputTex, st);
                float4 colorB = tex.Sample(sampler_tex, st);

                // Centered, aspect-correct coordinates.
                // WGSL: aspect = dims.x / dims.y  (inputTex dims, NOT fullResolution)
                float aspect = dims.x / dims.y;
                float2 p = (st - float2(0.5, 0.5)) * 2.0;
                p.x = p.x * aspect;

                // Apply position offset
                p = p - float2(posX * aspect, -posY);

                // Apply rotation
                float rad = rotation * NM_SM_PI / 180.0;
                p = rotate2D(p, rad);

                // Animate radius: pulse in and out
                float r = radius;
                [branch] if (speed > 0) {
                    r = radius * 0.5 + sin(time * NM_SM_TAU * (float)speed) * radius * 0.5;
                }

                return nm_shapeMask(colorA, colorB, p, r);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
