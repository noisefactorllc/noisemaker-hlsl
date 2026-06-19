Shader "Noisemaker/filter/clouds"
{
    // filter/clouds — ridged multi-octave simplex noise cloud overlay with shadow.
    // Single render pass (program "clouds"). Filter: samples inputTex.
    // Uniforms: seed (int), scale (float), speed (int).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "clouds" (definition.js passes[0].program)
        Pass
        {
            Name "clouds"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles

            #include "Clouds.hlsl"

            // Input surface. Bilinear, clamp-to-edge, linear (non-sRGB).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            static const float TAU = 6.28318530718;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let texSize = vec2<f32>(textureDimensions(inputTex));
                uint tw, th;
                inputTex.GetDimensions(tw, th);
                float2 texSize = float2(tw, th);

                // WGSL: let uv = (pos.xy + uniforms.tileOffset) / uniforms.fullResolution;
                float2 uv = (NM_FragCoord(i) + tileOffset) / fullResolution;

                float4 inputColor = inputTex.Sample(sampler_inputTex, uv);

                float aspect    = fullResolution.x / fullResolution.y;
                float2 seedOff  = float2((float)seed * 17.31, (float)seed * 23.71);

                // Animation phase (loops at 0-1 time boundary)
                float animPhase = time * TAU * (float)speed;
                float animSpeed = (float)speed;

                float2 cloudUV = uv * float2(aspect, 1.0) / scale + seedOff;

                float cloud     = nm_clouds_cloudNoise(cloudUV, 1.0, 7, animPhase, animSpeed);
                float cloudMask = smoothstep(0.45, 0.65, cloud);

                // Cloud shading: vary brightness within cloud for depth
                float cloudDepth      = smoothstep(0.45, 0.85, cloud);
                float cloudBrightness = lerp(0.75, 1.0, cloudDepth);

                // Shadow: sample cloud at offset (light from upper-right)
                // WGSL: shadowDist = min(texSize.x, texSize.y) * 0.008
                //       shadowOffset = vec2<f32>(-shadowDist, shadowDist) / texSize
                float shadowDist    = min(texSize.x, texSize.y) * 0.008;
                float2 shadowOffset = float2(-shadowDist, shadowDist) / texSize;
                float2 shadowUV     = (uv + shadowOffset) * float2(aspect, 1.0) / scale + seedOff;
                float shadowCloud   = nm_clouds_cloudNoise(shadowUV, 1.0, 7, animPhase, animSpeed);
                float shadowMask    = smoothstep(0.45, 0.65, shadowCloud);

                float shadow = max(shadowMask - cloudMask, 0.0) * 0.5;

                float3 result = inputColor.rgb * (1.0 - shadow);
                result = lerp(result, float3(cloudBrightness, cloudBrightness, cloudBrightness), cloudMask);

                return float4(result, inputColor.a);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
