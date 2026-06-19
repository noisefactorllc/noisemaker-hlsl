search filter, synth

noise(seed: 1, ridges: true)
  .sobel()
  .write(o0)

render(o0)
