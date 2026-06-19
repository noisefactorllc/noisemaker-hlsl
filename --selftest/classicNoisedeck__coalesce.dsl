search classicNoisedeck

noise(seed: 1, ridges: true)
  .write(o0)

noise(seed: 2, ridges: true)
  .coalesce(tex: read(o0))
  .write(o1)

render(o1)
