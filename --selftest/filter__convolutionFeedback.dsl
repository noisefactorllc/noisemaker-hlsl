search filter, synth

noise(seed: 1, ridges: true)
  .convolutionFeedback()
  .write(o0)

render(o0)
