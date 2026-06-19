Shader "Noisemaker/synth/navierStokes"
{
    // synth/navierStokes — stable-fluids Navier-Stokes solver. 7 passes per
    // frame in definition order: nsSplat, nsAdvect, nsDivergence, nsPressure
    // (repeat:iterations), nsGradient, nsSmooth, ns. Persistent state textures
    // global_ns_velocity (rg=vel, b=dye, a=init flag) and global_ns_pressure
    // (r=pressure, g=div) carry feedback across frames/within-frame; the
    // runtime ping-pongs them per write/iteration (reference 04 §10.2/§10.6/
    // §10.7). global_ns_smoothed is a transient full-res upsample target. The
    // runtime rebinds each pass's input/output textures and sets named uniforms
    // (and the inputTex sampler) via MaterialPropertyBlock by reference names.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "nsSplat" (passes[0]) — external force / source
        Pass
        {
            Name "nsSplat"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_nsSplat
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "NavierStokes.hlsl"
            ENDHLSL
        }

        // progName "nsAdvect" (passes[1]) — semi-Lagrangian advection + decay
        Pass
        {
            Name "nsAdvect"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_nsAdvect
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "NavierStokes.hlsl"
            ENDHLSL
        }

        // progName "nsDivergence" (passes[2]) — velocity divergence
        Pass
        {
            Name "nsDivergence"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_nsDivergence
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "NavierStokes.hlsl"
            ENDHLSL
        }

        // progName "nsPressure" (passes[3]) — Jacobi pressure (repeat:iterations)
        Pass
        {
            Name "nsPressure"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_nsPressure
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "NavierStokes.hlsl"
            ENDHLSL
        }

        // progName "nsGradient" (passes[4]) — gradient subtraction / projection
        Pass
        {
            Name "nsGradient"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_nsGradient
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "NavierStokes.hlsl"
            ENDHLSL
        }

        // progName "nsSmooth" (passes[5]) — kernel upsample → smoothed canvas
        Pass
        {
            Name "nsSmooth"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_nsSmooth
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "NavierStokes.hlsl"
            ENDHLSL
        }

        // progName "ns" (passes[6]) — display blit + input blend
        Pass
        {
            Name "ns"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_ns
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "NavierStokes.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
