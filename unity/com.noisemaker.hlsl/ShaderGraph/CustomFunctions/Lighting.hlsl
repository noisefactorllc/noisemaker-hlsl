#ifndef NM_SG_LIGHTING_INCLUDED
#define NM_SG_LIGHTING_INCLUDED

// =============================================================================
// ShaderGraph Custom Function wrapper for filter/lighting.
//
// Single-pass filter: samples InputTex, computes Sobel normals, applies
// Lambertian diffuse + Blinn-Phong specular + ambient + optional refraction
// and reflection (chromatic aberration).
//
// All helpers mirrored VERBATIM from Shaders/Effects/filter/Lighting.hlsl,
// name-prefixed `nmsg_` to avoid symbol clashes. Self-contained; does NOT
// include NMFullscreen.hlsl or NMCore.hlsl.
//
// TODO(verify): SS must be a clamp, non-sRGB (linear) sampler state to match
// the runtime's bilinear/clamp/linear path (H7).
// =============================================================================

float nmsg_lighting_getLuminosity(float3 color)
{
    return dot(color, float3(0.299, 0.587, 0.114));
}

float3 nmsg_lighting_calculateNormal(
    UnityTexture2D InputTex, UnitySamplerState SS,
    float2 uv, float2 texelSize,
    float normalStrength, float smoothing)
{
    float2 sampleSize = texelSize * smoothing;

    float sobel_x[9] = { -1.0, 0.0, 1.0,
                         -2.0, 0.0, 2.0,
                         -1.0, 0.0, 1.0 };
    float sobel_y[9] = { -1.0, -2.0, -1.0,
                          0.0,  0.0,  0.0,
                          1.0,  2.0,  1.0 };
    float2 offsets[9] = {
        float2(-sampleSize.x, -sampleSize.y),
        float2( 0.0,          -sampleSize.y),
        float2( sampleSize.x, -sampleSize.y),
        float2(-sampleSize.x,  0.0         ),
        float2( 0.0,           0.0         ),
        float2( sampleSize.x,  0.0         ),
        float2(-sampleSize.x,  sampleSize.y),
        float2( 0.0,           sampleSize.y),
        float2( sampleSize.x,  sampleSize.y)
    };

    float dx = 0.0;
    float dy = 0.0;
    for (int i = 0; i < 9; i = i + 1)
    {
        float4 s = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + offsets[i]);
        float  h = nmsg_lighting_getLuminosity(s.rgb);
        dx += h * sobel_x[i];
        dy += h * sobel_y[i];
    }
    dx *= normalStrength;
    dy *= normalStrength;
    return normalize(float3(-dx, -dy, 1.0));
}

float4 nmsg_lighting_applyRefraction(
    UnityTexture2D InputTex, UnitySamplerState SS,
    float2 uv, float3 normal, float refraction)
{
    float2 refractionOffset = normal.xy * (refraction * 0.0125);
    return SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + refractionOffset);
}

float4 nmsg_lighting_applyReflection(
    UnityTexture2D InputTex, UnitySamplerState SS,
    float2 uv, float3 normal, float reflection, float aberration)
{
    float3 incident      = float3(normalize(uv - float2(0.5, 0.5)), 100.0);
    float3 reflectionVec = reflect(incident, normal);
    float2 reflectionOffset = reflectionVec.xy * (reflection * 0.00005);

    float2 redOffset   = reflectionOffset * (1.0 + aberration * 0.0075);
    float2 greenOffset = reflectionOffset;
    float2 blueOffset  = reflectionOffset * (1.0 - aberration * 0.0075);

    float r = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + redOffset  ).r;
    float g = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + greenOffset ).g;
    float b = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + blueOffset  ).b;
    float a = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, uv + reflectionOffset).a;
    return float4(r, g, b, a);
}

// Shader Graph Custom Function entry point.
// UV must be the input-texture-space 0..1 coordinate (fragCoord / texDims).
void NM_Lighting_float(
    UnityTexture2D InputTex,
    UnitySamplerState SS,
    float2  UV,
    float   NormalStrength,
    float   Smoothing,
    float3  DiffuseColor,
    float3  SpecularColor,
    float   SpecularIntensity,
    float   Shininess,
    float3  AmbientColor,
    float3  LightDirection,
    float   Reflection,
    float   Refraction,
    float   Aberration,
    out float4 Out)
{
    float texW, texH;
    InputTex.tex.GetDimensions(texW, texH);
    float2 texSize   = float2(texW, texH);
    float2 texelSize = 1.0 / texSize;

    float4 origColor = SAMPLE_TEXTURE2D(InputTex.tex, SS.samplerstate, UV);
    float3 normal    = nmsg_lighting_calculateNormal(InputTex, SS, UV, texelSize,
                           NormalStrength, Smoothing);
    float3 lightDir  = normalize(LightDirection);
    float3 viewDir   = float3(0.0, 0.0, 1.0);

    float3 ambient       = AmbientColor * origColor.rgb;
    float  diffuseFactor = max(dot(normal, lightDir), 0.0);
    float3 diffuse       = DiffuseColor * diffuseFactor * origColor.rgb;
    float3 halfDir       = normalize(lightDir + viewDir);
    float  specAngle     = max(dot(halfDir, normal), 0.0);
    float  specFactor    = pow(specAngle, Shininess);
    float3 specular      = SpecularColor * specFactor * SpecularIntensity;

    float3 litColor     = ambient + diffuse + specular;
    float4 workingColor = float4(litColor, origColor.a);

    [branch]
    if (Refraction > 0.0)
    {
        float4 refractedColor = nmsg_lighting_applyRefraction(InputTex, SS, UV,
                                    normal, Refraction);
        workingColor = lerp(workingColor, refractedColor, Refraction / 100.0);
    }

    [branch]
    if (Reflection > 0.0 || Aberration > 0.0)
    {
        float4 reflectedColor = nmsg_lighting_applyReflection(InputTex, SS, UV,
                                    normal, Reflection, Aberration);
        workingColor = lerp(workingColor, reflectedColor, Reflection / 100.0);
    }

    Out = workingColor;
}

#endif // NM_SG_LIGHTING_INCLUDED
