Shader "Noisemaker/synth/mandelbrot"
{
    // synth/mandelbrot — df64 deep-zoom Mandelbrot explorer. Single render pass.
    // Runtime binds params via MaterialPropertyBlock by the names declared in
    // Mandelbrot.hlsl: poi, outputMode, iterations, centerHiX, centerHiY,
    // centerLoX, centerLoY, zoomSpeed, zoomDepth, invert, stripeFreq,
    // trapShape, lightAngle, rotation.
    // The Properties block is for inspector convenience only.

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        // Pass name matches definition.js passes[0].program = "mandelbrot"
        Pass
        {
            Name "mandelbrot"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            // Full 32-bit float; no half/min16float (df64 is bit-sensitive).
            #pragma exclude_renderers gles
            #include "Mandelbrot.hlsl"

            // No texture inputs (synth generator).

            float4 frag(NMVaryings i) : SV_Target
            {
                // GLSL source: globalCoord = gl_FragCoord.xy + tileOffset, and
                // transformCoords divides by fullResolution. The WGSL collapses
                // tiling (its uniform resolution == fullResolution, pos.xy ==
                // globalCoord). For Unity tiled-render parity we use the global
                // coord and fullResolution; both reduce to the untiled case when
                // tileOffset==0 and resolution==fullResolution.
                float2 globalCoord = NM_GlobalCoord(i);
                return nm_mandelbrot(globalCoord, fullResolution);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
