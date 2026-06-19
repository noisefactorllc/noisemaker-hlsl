Shader "Noisemaker/points/life"
{
    // points/life — Particle-Life: type-based attraction/repulsion particle
    // simulation. Agent-based MIDDLEWARE. 3 passes per frame in definition order:
    //   matrix       (fullscreen)        — builds the 8x8 forceMatrix from seed.
    //   agent        (fullscreen, MRT 4) — force eval + integration; reads the
    //                  PERSISTENT particle surfaces global_xyz/global_vel/
    //                  global_rgba + internal global_life_data + forceMatrix +
    //                  inputTex, writes all 4 state textures via MRT
    //                  (SV_Target0..3 == location0..3 == xyz,vel,rgba,data).
    //   passthrough  (fullscreen)        — copies inputTex -> outputTex.
    // No deposit / drawMode:"points" pass exists in this effect (the points
    // scatter lives in the downstream points/pointsRender effect). All passes are
    // fullscreen (NMVertFullscreen); no custom scatter vertex is needed here.
    // State surfaces global_xyz/global_vel/global_rgba (and global_life_data via
    // its global_ prefix) are double-buffered/ping-ponged by the runtime so the
    // agent pass never reads and writes the same buffer (ref 04 §10.2/§10.7;
    // isStateSurface matches xyz|vel|rgba). The runtime rebinds each pass's
    // input/output textures and sets named uniforms via MaterialPropertyBlock.


    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off

        // progName "matrix" (passes[0]) — ForceMatrix generator
        Pass
        {
            Name "matrix"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_matrix
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Life.hlsl"
            ENDHLSL
        }

        // progName "agent" (passes[1]) — force eval + integration, MRT 4 outputs
        Pass
        {
            Name "agent"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_agent
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Life.hlsl"
            ENDHLSL
        }

        // progName "passthrough" (passes[2]) — copy inputTex -> outputTex
        Pass
        {
            Name "passthrough"
            Blend Off
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag_passthrough
            #pragma target 4.5
            #pragma exclude_renderers gles
            #include "Life.hlsl"
            ENDHLSL
        }
    }
    Fallback Off
}
