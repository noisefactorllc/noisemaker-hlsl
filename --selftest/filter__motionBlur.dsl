search filter, synth

noise(seed: 1, ridges: true)
  .motionBlur()
  .write(o0)

render(o0)
