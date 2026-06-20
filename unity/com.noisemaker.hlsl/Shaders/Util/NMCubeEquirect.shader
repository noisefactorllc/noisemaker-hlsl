Shader "Hidden/Noisemaker/NMCubeEquirect"
{
    // PARITY UTILITY (not an effect): projects a TextureCube into an equirectangular
    // 2:1 image by sampling the cube with Unity's HARDWARE cube sampler across all
    // directions. Used to verify that an assembled NMCubemap is seamless and correctly
    // oriented under Unity's (D3D) cube-sampling convention vs the reference's
    // directional sampling. Blit(null, equirectRT, mat) with mat._NMCube = the cube.
    //
    // Direction mapping (must match parity/cube-equirect-ref.mjs):
    //   uv in [0,1] (row 0 = top after readback); optional _FlipY toggles uv.y.
    //   lon = (uv.x - 0.5) * 2*PI ;  lat = (0.5 - vy) * PI    (top = +PI/2)
    //   dir = (cos(lat)sin(lon), sin(lat), cos(lat)cos(lon))   (y-up, +Z at lon=0)
    Properties
    {
        _NMCube ("Cube", Cube) = "" {}
        _Res ("Equirect size (xy)", Vector) = (512,256,0,0)
    }
    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        Pass
        {
            ZTest Always Cull Off ZWrite Off
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "UnityCG.cginc"

            samplerCUBE _NMCube;
            float4 _Res;   // .xy = equirect width,height
            float _Debug;  // >0.5: output the sampling DIRECTION (dir*0.5+0.5) not the cube

            struct appdata { float4 vertex : POSITION; };
            struct v2f { float4 pos : SV_POSITION; };

            v2f vert (appdata v) { v2f o; o.pos = UnityObjectToClipPos(v.vertex); return o; }

            float4 frag (v2f i) : SV_Target
            {
                const float PI = 3.14159265358979;
                // SV_Position pixel coords, origin TOP-LEFT in Unity (D3D), +0.5 centered.
                // Matches the reference equirect's row-0-is-top (+PI/2 lat) convention with
                // NO blit-uv guesswork, so a correctly-oriented cube matches under identity.
                float2 uv = i.pos.xy / _Res.xy;
                float lon = (uv.x - 0.5) * 2.0 * PI;
                // Graphics.Blit + ReadPixels flips vertically vs SV_Position here, so the
                // readback row 0 is the BOTTOM scanline. Compensate (lat = (uv.y-0.5)*PI)
                // so the written PNG is row-0-is-top (+Y), matching the reference equirect
                // and every other parity PNG. (Verified by the direction-debug control.)
                float lat = (uv.y - 0.5) * PI;
                float3 dir = float3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon));
                if (_Debug > 0.5) return float4(dir * 0.5 + 0.5, 1.0);
                return texCUBElod(_NMCube, float4(dir, 0.0));
            }
            ENDCG
        }
    }
    Fallback Off
}
