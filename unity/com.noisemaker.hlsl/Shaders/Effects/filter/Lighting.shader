Shader "Noisemaker/filter/lighting"
{
    // filter/lighting — 3D lighting for 2D textures via Sobel normal estimation.
    // Lambertian diffuse + Blinn-Phong specular + ambient + optional refraction
    // and reflection (chromatic aberration). Single render pass.
    // Runtime binds all uniforms via MaterialPropertyBlock using the exact names
    // from definition.js globals[*].uniform.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "lighting" (definition.js passes[0].program)
        Pass
        {
            Name "lighting"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment NMFrag_lighting
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Lighting.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
