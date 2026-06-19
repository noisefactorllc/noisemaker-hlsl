Shader "Noisemaker/filter/smooth"
{
    // filter/smooth — two-pass anti-aliasing (MSAA / SMAA / edge-selective Blur).
    // Pass "smoothEdge": inputTex -> internal _smoothEdges (luma edge map; MSAA
    // passes through). Pass "smoothBlend": inputTex + edgeTex(_smoothEdges) ->
    // output. The runtime drives both passes in order, allocates _smoothEdges,
    // and rebinds edgeTex = _smoothEdges for pass 2. Inspector-only Properties;
    // the runtime binds the uniforms (and the inputTex sampler) via a
    // MaterialPropertyBlock using the reference uniform names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // progName "smoothEdge" (definition.js passes[0].program) — edge detection
        Pass
        {
            Name "smoothEdge"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_smoothEdge
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Smooth.hlsl"
            ENDHLSL
        }

        // progName "smoothBlend" (definition.js passes[1].program) — blend pass
        Pass
        {
            Name "smoothBlend"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_smoothBlend
            #pragma target 4.5
            // Full 32-bit float; no half/min16float promotion (parity requirement).
            #pragma exclude_renderers gles
            #include "Smooth.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
