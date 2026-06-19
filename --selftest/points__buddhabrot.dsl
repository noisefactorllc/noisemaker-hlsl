search points, synth, render

solid()
  .pointsEmit(stateSize: 512)
  .buddhabrot()
  .pointsRender(intensity: 99)
  .write(o0)

render(o0)
