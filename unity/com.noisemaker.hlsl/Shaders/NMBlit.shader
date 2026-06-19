Shader "Noisemaker/Blit"
{
    // Straight fullscreen copy between linear ARGBHalf RenderTextures. Used for the
    // graph's blit passes (chain-handoff `_write` and the final blit). The reference
    // blit program samples its input under the name `src` (inputs:{src:...}); the
    // backend binds it via SetGlobalTexture("src", rt), so the sampler MUST be `src`.
    // Single Y-reconciliation point (toggle NM_FLIP_Y in NMCore.hlsl); default is a
    // straight copy — content is generated top-left (WGSL convention) by
    // NMVertFullscreen, so no flip is needed between same-orientation RenderTextures.
    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        ZWrite Off ZTest Always Cull Off Blend Off

        Pass
        {
            Name "blit"
            HLSLPROGRAM
            #pragma vertex NMVertFullscreen
            #pragma fragment frag
            #pragma target 4.5
            #include "Include/NMFullscreen.hlsl"

            Texture2D    src;            // bound by the backend as a global texture
            SamplerState sampler_src;    // bilinear clamp from the source RT

            float4 frag(NMVaryings i) : SV_Target
            {
                return src.Sample(sampler_src, i.uv);
            }
            ENDHLSL
        }
    }
    Fallback Off
}
