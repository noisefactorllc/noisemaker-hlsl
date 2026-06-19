search classicNoisedeck

noise(seed: 1, ridges: true)
  .write(o0)

cellNoise(tex: read(o0))
  .write(o1)

render(o1)
