Shader "Noisemaker/filter/strayHair"
{
    // filter/strayHair — composites a CPU-rendered hair overlay onto inputTex.
    // Single render pass (program "strayHairBlend"). The overlayTex is produced by
    // asyncInit (CPU canvas / traceWorms); the GPU only blends it with inputTex.
    // WGSL uses textureLoad (integer pixel coords) for both inputs — we mirror this
    // with Texture2D.Load(int3(x,y,0)) and declare the SamplerState objects only to
    // satisfy the engine property binding system (they are not used for samples).

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "strayHairBlend" (definition.js passes[0].program)
        Pass
        {
            Name "strayHairBlend"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "StrayHair.hlsl"

            // Input surface (the upstream render texture).
            Texture2D    inputTex;
            SamplerState sampler_inputTex;

            // CPU-rendered hair overlay (rgba8 canvas, uploaded each frame by asyncInit).
            Texture2D    overlayTex;
            SamplerState sampler_overlayTex;

            float4 frag(NMVaryings i) : SV_Target
            {
                // WGSL: let coord = vec2<i32>(i32(pos.x), i32(pos.y));
                // NM_FragCoord gives pixel center (+0.5); truncate to integer index.
                // Use (int) not (uint) — WGSL uses i32.
                int2 coord = (int2)NM_FragCoord(i);

                // WGSL: let base    = textureLoad(inputTex,   coord, 0);
                // WGSL: let overlay = textureLoad(overlayTex, coord, 0);
                float4 base    = inputTex  .Load(int3(coord, 0));
                float4 overlay = overlayTex.Load(int3(coord, 0));

                return nm_strayHairBlend(base, overlay, alpha);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
