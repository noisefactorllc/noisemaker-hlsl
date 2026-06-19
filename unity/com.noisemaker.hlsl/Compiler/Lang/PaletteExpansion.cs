// PaletteExpansion.cs — classicNoisedeck cosine-palette index expansion, a port of
// shaders/src/runtime/palette-expansion.js (reference/03 §7).
//
// A type:'palette' global holds a 1-BASED integer index; ExpandPalette(index) maps it
// to five concrete uniforms: paletteOffset/Amp/Freq/Phase (vec3) + paletteMode (int).
// index <= 0 || index > 55 -> null.
//
// PARITY: the 55 float constants are copied VERBATIM from reference/03 §7 (several are
// non-round, e.g. 0.56851584). mode is classicNoisedeck convention (0=none,1=hsv,
// 2=oklab,3=rgb). This 1-based index is DISTINCT from the 0-based palette ENUM
// (reference/03 §8 hazard) — do not conflate.
//
// Pure C#, no UnityEngine.

using System.Collections.Generic;

namespace Noisemaker.Hlsl.Compiler
{
    public sealed class PaletteEntry
    {
        public double[] Amp;
        public double[] Freq;
        public double[] Offset;
        public double[] Phase;
        public int Mode;
        public PaletteEntry(double[] amp, double[] freq, double[] offset, double[] phase, int mode)
        { Amp = amp; Freq = freq; Offset = offset; Phase = phase; Mode = mode; }
    }

    public static class PaletteExpansion
    {
        private static double[] V(double a, double b, double c) { return new[] { a, b, c }; }

        // 55 entries, index 1..55 (reference/03 §7 full table, verbatim floats).
        public static readonly PaletteEntry[] Palettes =
        {
            new PaletteEntry(V(.76,.88,.37), V(1,1,1), V(.93,.97,.52), V(.21,.41,.56), 3),                              // 1 seventiesShirt
            new PaletteEntry(V(.56851584,.7740668,.23485267), V(1,1,1), V(.5,.5,.5), V(.727029,.08039695,.10427457), 3), // 2 fiveG
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.5,.5,.5), V(.3,.2,.2), 3),                                       // 3 afterimage
            new PaletteEntry(V(.45,.2,.1), V(1,1,1), V(.7,.2,.2), V(.5,.4,0), 3),                                       // 4 barstow
            new PaletteEntry(V(.09,.59,.48), V(1,1,1), V(.2,.31,.98), V(.88,.4,.33), 3),                                // 5 bloob
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.1,.4,.7), V(.1,.1,.1), 3),                                       // 6 blueSkies
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.5,.5,.5), V(0,.1,.2), 3),                                        // 7 brushedMetal
            new PaletteEntry(V(.7259015,.7004237,.9494409), V(1,1,1), V(.63290054,.37883538,.29405284), V(0,.1,.2), 3), // 8 burningSky
            new PaletteEntry(V(.94,.33,.27), V(1,1,1), V(.74,.37,.73), V(.44,.17,.88), 3),                              // 9 california
            new PaletteEntry(V(1,.7,1), V(1,1,1), V(1,.4,.9), V(.4,.5,.6), 3),                                          // 10 columbia
            new PaletteEntry(V(.51,.39,.41), V(1,1,1), V(.59,.53,.94), V(.15,.41,.46), 3),                              // 11 cottonCandy
            new PaletteEntry(V(0,0,.51), V(1,1,1), V(0,0,.43), V(0,0,.36), 1),                                          // 12 darkSatin
            new PaletteEntry(V(.83,.45,.19), V(1,1,1), V(.79,.45,.35), V(.28,.91,.61), 3),                              // 13 dealerHat
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.5,.5,.5), V(0,.2,.25), 3),                                       // 14 dreamy
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.22,.48,.62), V(.1,.3,.2), 3),                                    // 15 eventHorizon
            new PaletteEntry(V(.02,.92,.76), V(1,1,1), V(.51,.49,.51), V(.71,.23,.66), 1),                              // 16 ghostly
            new PaletteEntry(V(.5,.5,.5), V(2,2,2), V(.5,.5,.5), V(1,1,1), 3),                                          // 17 grayscale
            new PaletteEntry(V(.79,.56,.22), V(1,1,1), V(.96,.5,.49), V(.15,.98,.87), 3),                               // 18 hazySunset
            new PaletteEntry(V(.75804377,.62868536,.2227562), V(1,1,1), V(.35536355,.12935615,.17060602), V(0,.25,.5), 3), // 19 heatmap
            new PaletteEntry(V(.79,.5,.23), V(1,1,1), V(.75,.47,.45), V(.08,.84,.16), 3),                               // 20 hypercolor
            new PaletteEntry(V(.7,.81,.73), V(1,1,1), V(.1,.22,.27), V(.99,.12,.94), 3),                                // 21 jester
            new PaletteEntry(V(.5,.5,.5), V(0,0,1), V(.5,.5,.5), V(.5,.5,.5), 3),                                       // 22 justBlue
            new PaletteEntry(V(.5,.5,.5), V(0,1,1), V(.5,.5,.5), V(.5,.5,.5), 3),                                       // 23 justCyan
            new PaletteEntry(V(.5,.5,.5), V(0,1,0), V(.5,.5,.5), V(.5,.5,.5), 3),                                       // 24 justGreen
            new PaletteEntry(V(.5,.5,.5), V(1,0,1), V(.5,.5,.5), V(.5,.5,.5), 3),                                       // 25 justPurple
            new PaletteEntry(V(.5,.5,.5), V(1,0,0), V(.5,.5,.5), V(.5,.5,.5), 3),                                       // 26 justRed
            new PaletteEntry(V(.5,.5,.5), V(1,1,0), V(.5,.5,.5), V(.5,.5,.5), 3),                                       // 27 justYellow
            new PaletteEntry(V(.74,.33,.09), V(1,1,1), V(.62,.2,.2), V(.2,.1,0), 3),                                    // 28 mars
            new PaletteEntry(V(.56,.68,.39), V(1,1,1), V(.72,.07,.62), V(.25,.4,.41), 3),                               // 29 modesto
            new PaletteEntry(V(.78,.39,.07), V(1,1,1), V(0,.53,.33), V(.94,.92,.9), 3),                                 // 30 moss
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.2,.64,.62), V(.15,.2,.3), 3),                                    // 31 neptune
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.64,.12,.84), V(.1,.25,.15), 3),                                  // 32 netOfGems
            new PaletteEntry(V(.42,.42,.04), V(1,1,1), V(.47,.27,.27), V(.41,.14,.11), 3),                              // 33 organic
            new PaletteEntry(V(.65,.4,.11), V(1,1,1), V(.72,.45,.08), V(.71,.8,.84), 3),                                // 34 papaya
            new PaletteEntry(V(.62,.79,.11), V(1,1,1), V(.22,.56,.17), V(.15,.1,.25), 3),                               // 35 radioactive
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.41,.22,.67), V(.2,.25,.2), 3),                                   // 36 royal
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.5,.5,.5), V(.25,.5,.75), 3),                                     // 37 santaCruz
            new PaletteEntry(V(.6059281,.17591387,.17166573), V(1,1,1), V(.5224456,.3864609,.36020845), V(0,.25,.5), 3),// 38 sherbet
            new PaletteEntry(V(.6059281,.17591387,.17166573), V(2,2,2), V(.5224456,.3864609,.36020845), V(0,.25,.5), 3),// 39 sherbetDouble
            new PaletteEntry(V(.42,0,0), V(2,2,2), V(.45,.5,.42), V(.63,1,1), 2),                                       // 40 silvermane
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.83,.6,.63), V(.3,.1,0), 3),                                      // 41 skykissed
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.6,.4,.1), V(.3,.2,.1), 3),                                       // 42 solaris
            new PaletteEntry(V(.46,.73,.19), V(1,1,1), V(.27,.79,.78), V(.27,.16,.04), 2),                              // 43 spooky
            new PaletteEntry(V(.67,.25,.27), V(1,1,1), V(.74,.48,.46), V(.07,.79,.39), 3),                              // 44 springtime
            new PaletteEntry(V(.9,.43,.34), V(1,1,1), V(.56,.69,.32), V(.03,.8,.4), 3),                                 // 45 sproingtime
            new PaletteEntry(V(.73,.36,.52), V(1,1,1), V(.78,.68,.15), V(.74,.93,.28), 3),                              // 46 sulphur
            new PaletteEntry(V(1,0,.8), V(1,1,1), V(0,0,0), V(0,.5,.1), 3),                                             // 47 summoning
            new PaletteEntry(V(1,.25,.5), V(.5,.5,.5), V(0,0,.25), V(.5,0,0), 3),                                       // 48 superhero
            new PaletteEntry(V(.5,.5,.5), V(1,1,1), V(.26,.57,.03), V(0,.1,.3), 3),                                     // 49 toxic
            new PaletteEntry(V(.28,.08,.65), V(1,1,1), V(.48,.6,.03), V(.1,.15,.3), 2),                                 // 50 tropicalia
            new PaletteEntry(V(.65,.93,.73), V(1,1,1), V(.31,.21,.27), V(.43,.45,.48), 3),                              // 51 tungsten
            new PaletteEntry(V(.9,.76,.63), V(1,1,1), V(0,.19,.68), V(.43,.23,.32), 3),                                 // 52 vaporwave
            new PaletteEntry(V(.78,.63,.68), V(1,1,1), V(.41,.03,.16), V(.81,.61,.06), 3),                              // 53 vibrant
            new PaletteEntry(V(.97,.74,.23), V(1,1,1), V(.97,.38,.35), V(.34,.41,.44), 3),                              // 54 vintage
            new PaletteEntry(V(.68,.79,.57), V(1,1,1), V(.56,.35,.14), V(.73,.9,.99), 3),                               // 55 vintagePhoto
        };

        // Returns the five expanded uniforms (insertion-ordered) or null when out of range.
        public static List<KeyValuePair<string, double[]>> ExpandVectors(double index)
        {
            int idx = (int)index;
            if (idx <= 0 || idx > 55) return null;
            PaletteEntry e = Palettes[idx - 1];
            return new List<KeyValuePair<string, double[]>>
            {
                new KeyValuePair<string, double[]>("paletteOffset", (double[])e.Offset.Clone()),
                new KeyValuePair<string, double[]>("paletteAmp", (double[])e.Amp.Clone()),
                new KeyValuePair<string, double[]>("paletteFreq", (double[])e.Freq.Clone()),
                new KeyValuePair<string, double[]>("palettePhase", (double[])e.Phase.Clone()),
            };
        }

        public static int? ExpandMode(double index)
        {
            int idx = (int)index;
            if (idx <= 0 || idx > 55) return null;
            return Palettes[idx - 1].Mode;
        }
    }
}
