#ifndef NM_TETRACOSINE_SG_INCLUDED
#define NM_TETRACOSINE_SG_INCLUDED

// =============================================================================
// ShaderGraph/CustomFunctions/TetraCosine.hlsl
//
// Shader Graph Custom Function wrapper for filter/tetraCosine.
// Add a Custom Function node, point it at this file, select NM_TetraCosine_float,
// and wire all inputs. Outputs RGBA.
//
// UV must be 0..1, top-left origin (WGSL convention). The function samples
// InputTex at UV (after converting back to fragment pixel coords) then applies
// the cosine palette based on luminance exactly as the runtime pass does.
//
// NOTE: `time` is sourced from the NMFullscreen.hlsl engine global. In a Shader
// Graph context, pass _Time.y (or the equivalent) as the Time input.
// =============================================================================

#include "../../Shaders/Effects/filter/TetraCosine.hlsl"

void NM_TetraCosine_float(
    UnityTexture2D    InputTex,
    UnitySamplerState SS,
    float2            UV,
    int               ColorMode,
    float             OffsetR,
    float             OffsetG,
    float             OffsetB,
    float             AmpR,
    float             AmpG,
    float             AmpB,
    int               FreqR,
    int               FreqG,
    int               FreqB,
    float             PhaseR,
    float             PhaseG,
    float             PhaseB,
    int               Rotation,
    float             Repeat,
    float             Offset,
    float             Alpha,
    float             Time,
    out float4        Out)
{
    // Write inputs into the per-effect uniforms declared in TetraCosine.hlsl
    colorMode = ColorMode;
    offsetR   = OffsetR;
    offsetG   = OffsetG;
    offsetB   = OffsetB;
    ampR      = AmpR;
    ampG      = AmpG;
    ampB      = AmpB;
    freqR     = FreqR;
    freqG     = FreqG;
    freqB     = FreqB;
    phaseR    = PhaseR;
    phaseG    = PhaseG;
    phaseB    = PhaseB;
    rotation  = Rotation;
    repeat    = Repeat;
    offset    = Offset;
    alpha     = Alpha;
    // Override engine time for SG context // TODO(verify): NMFullscreen `time` may shadow this
    time      = Time;

    // Convert 0-1 UV to pixel-centre fragment coordinate for nm_tetraCosine
    uint tw, th;
    InputTex.tex.GetDimensions(tw, th);
    float2 fragCoord = UV * float2(tw, th);

    Out = nm_tetraCosine(InputTex.tex, SS.samplerstate, fragCoord);
}

#endif // NM_TETRACOSINE_SG_INCLUDED
