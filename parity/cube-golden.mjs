#!/usr/bin/env node
// cube-golden.mjs — GOLDEN renderer for the 6 cube faces of a renderCubemap* program.
//
// The sibling of export-and-render.mjs for seamless-cubemap effects. It drives the
// reference pipeline.renderCubemap loop EXPLICITLY (setUniform('cubeBasis', BASES[f])
// + render, per face) using the canonical reference CUBE_FACE_BASES, and reads each
// face back with the SAME linear-float readback + bottom-up→top-down flip as
// export-and-render.mjs — so the 6 golden PNGs are directly comparable to the Unity
// candidate faces written by NMParityRunner.RenderCubemapFromCommandLine.
//
// Usage:
//   node cube-golden.mjs <program.dsl> <outDir> [--time 0.25] [--size 256] \
//        [--backend webgl2|webgpu]
//
// Writes  <outDir>/<programName>.graph.json  and
//         <outDir>/<programName>.cube.golden_<face>.png  (face in px,nx,py,ny,pz,nz)
//
// Prereqs identical to export-and-render.mjs (Node, Playwright + system Chrome, the
// reference repo as the sibling tree). See parity/README.md.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve, basename, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { deflateSync } from 'node:zlib'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REFERENCE_ROOT = process.env.NM_REFERENCE_ROOT
  ? resolve(process.env.NM_REFERENCE_ROOT)
  : resolve(__dirname, '..', '..', 'noisemaker')

const HARNESS = join(REFERENCE_ROOT, 'vendor', 'shade-mcp', 'harness', 'index.js')
const EXPORT_GRAPH = join(__dirname, '..', 'tools', 'export-graph.mjs')
const CUBE_CAMERA = join(REFERENCE_ROOT, 'shaders', 'src', 'renderer', 'cubeCamera.js')

const FACE_NAMES = ['px', 'nx', 'py', 'ny', 'pz', 'nz']

// ---- self-contained PNG encoder (top-down RGBA8), copied from export-and-render ----
function crc32 (buf) {
  let c = 0xffffffff
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i]
    for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1)
  }
  return (c ^ 0xffffffff) >>> 0
}
function pngChunk (type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0)
  const typeBuf = Buffer.from(type, 'ascii')
  const body = Buffer.concat([typeBuf, data])
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body), 0)
  return Buffer.concat([len, body, crc])
}
function encodePng (width, height, rgbaTopDown) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0
  const raw = Buffer.alloc(height * (1 + width * 4))
  for (let y = 0; y < height; y++) {
    const di = y * (1 + width * 4)
    raw[di] = 0
    rgbaTopDown.copy(raw, di + 1, y * width * 4, (y + 1) * width * 4)
  }
  const idat = deflateSync(raw)
  return Buffer.concat([sig, pngChunk('IHDR', ihdr), pngChunk('IDAT', idat), pngChunk('IEND', Buffer.alloc(0))])
}

const VIEWER_ROOT = REFERENCE_ROOT
const VIEWER_PATH = '/demo/shaders/'
const EFFECTS_DIR = join(REFERENCE_ROOT, 'shaders', 'effects')
const GLOBALS_PREFIX = '__noisemaker'
const STATUS_TIMEOUT = 300000

function parseArgs (argv) {
  const opts = { time: 0.25, size: 256, backend: 'webgl2' }
  const pos = []
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--time') opts.time = parseFloat(argv[++i])
    else if (a === '--size') opts.size = parseInt(argv[++i], 10)
    else if (a === '--backend') opts.backend = argv[++i]
    else pos.push(a)
  }
  opts.programPath = pos[0]
  opts.outDir = pos[1]
  return opts
}

async function main () {
  const opts = parseArgs(process.argv.slice(2))
  if (!opts.programPath || !opts.outDir) {
    process.stderr.write('usage: node cube-golden.mjs <program.dsl> <outDir> ' +
      '[--time 0.25] [--size 256] [--backend webgl2|webgpu]\n')
    process.exit(2)
  }

  const dsl = readFileSync(opts.programPath, 'utf8')
  const programName = basename(opts.programPath).replace(/\.dsl$/, '')
  mkdirSync(opts.outDir, { recursive: true })

  // Canonical reference face bases (column-major [right|up|forward]).
  const { CUBE_FACE_BASES } = await import(pathToFileURL(CUBE_CAMERA).href)
  const bases = CUBE_FACE_BASES.map(b => Array.from(b))

  // Export the normalized graph (no browser needed) for reference/debugging.
  const { exportGraph } = await import(pathToFileURL(EXPORT_GRAPH).href)
  const graph = await exportGraph(dsl)
  writeFileSync(join(opts.outDir, `${programName}.graph.json`), JSON.stringify(graph, null, 2) + '\n')

  process.env.SHADE_VIEWER_ROOT = VIEWER_ROOT
  process.env.SHADE_VIEWER_PATH = VIEWER_PATH
  process.env.SHADE_EFFECTS_DIR = EFFECTS_DIR
  process.env.SHADE_GLOBALS_PREFIX = GLOBALS_PREFIX
  process.env.SHADE_HEADLESS = process.env.SHADE_HEADLESS ?? '1'

  const harness = await import(pathToFileURL(HARNESS).href)
  const { BrowserSession } = harness

  const session = new BrowserSession({ backend: opts.backend })
  let faces
  try {
    await session.setup()
    const page = session.page
    await session.setBackend(opts.backend)
    const globals = session.globals

    await page.setViewportSize({ width: opts.size, height: opts.size })
    await page.waitForFunction(() => !!window.__noisemakerRenderingPipeline &&
      !!document.getElementById('dsl-editor') && !!document.getElementById('dsl-run-btn'),
    { timeout: STATUS_TIMEOUT })

    const baselineId = await page.evaluate(() =>
      window.__noisemakerRenderingPipeline?.graph?.id ?? null)
    await page.evaluate((src) => {
      const editor = document.getElementById('dsl-editor')
      const runBtn = document.getElementById('dsl-run-btn')
      editor.value = src
      editor.dispatchEvent(new Event('input', { bubbles: true }))
      runBtn.click()
    }, dsl)
    await page.waitForFunction((base) => {
      const s = (document.getElementById('status')?.textContent || '').toLowerCase()
      if (s.includes('error') || s.includes('failed')) {
        throw new Error('DSL compile failed: ' + document.getElementById('status')?.textContent)
      }
      const p = window.__noisemakerRenderingPipeline
      return !!(p && p.graph && p.graph.id !== base)
    }, { timeout: STATUS_TIMEOUT }, baselineId)

    await page.evaluate(() => { if (window.__noisemakerSetPaused) window.__noisemakerSetPaused(true) })
    await page.evaluate((size) => {
      const r = window.__noisemakerCanvasRenderer
      const p = window.__noisemakerRenderingPipeline
      if (r && r.canvas) {
        r.canvas.width = size; r.canvas.height = size
        if (r.canvas.style) { r.canvas.style.width = size + 'px'; r.canvas.style.height = size + 'px' }
      }
      if (p && typeof p.resize === 'function') p.resize(size, size)
    }, opts.size)

    // Drive the 6-face loop: set cubeBasis per face, render deterministic frames,
    // read back o0 as linear float (the SAME readback as export-and-render.mjs).
    const result = await page.evaluate(({ g, bases, time, frames }) => {
      const pipeline = window[g.renderingPipeline]
      if (!pipeline) return { status: 'error', error: 'no pipeline' }
      const backend = pipeline.backend
      const gl = backend?.gl
      if (!gl) return { status: 'error', error: 'no GL' }
      if (window.__noisemakerSetPausedTime) window.__noisemakerSetPausedTime(time)

      function readO0 () {
        const surface = pipeline.surfaces?.get(pipeline.graph?.renderSurface || 'o0')
        const info = backend.textures?.get(surface.read)
        if (!info?.handle) return null
        const { handle, width, height, glFormat } = info
        const fbo = gl.createFramebuffer()
        gl.bindFramebuffer(gl.FRAMEBUFFER, fbo)
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, handle, 0)
        const canFloat = !!(gl.getExtension('EXT_color_buffer_float') || gl.getExtension('WEBGL_color_buffer_float'))
        const isFloat = glFormat?.type === gl.HALF_FLOAT || glFormat?.type === gl.FLOAT
        gl.finish()
        let rgba8
        if (isFloat && canFloat) {
          const buf = new Float32Array(width * height * 4)
          gl.readPixels(0, 0, width, height, gl.RGBA, gl.FLOAT, buf)
          rgba8 = new Array(width * height * 4)
          for (let i = 0; i < buf.length; i++) rgba8[i] = Math.max(0, Math.min(255, Math.round(buf[i] * 255)))
        } else {
          const buf = new Uint8Array(width * height * 4)
          gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, buf)
          rgba8 = Array.from(buf)
        }
        gl.bindFramebuffer(gl.FRAMEBUFFER, null)
        gl.deleteFramebuffer(fbo)
        return { width, height, pixels: rgba8 }
      }

      const out = []
      for (let f = 0; f < 6; f++) {
        pipeline.setUniform('cubeBasis', bases[f])
        for (let i = 0; i < frames; i++) pipeline.render(time)
        const r = readO0()
        if (!r) return { status: 'error', error: 'face ' + f + ' readback failed' }
        out.push(r)
      }
      return { status: 'ok', faces: out }
    }, { g: globals, bases, time: opts.time, frames: 8 })

    if (result.status === 'error') throw new Error(`cube readback failed: ${result.error}`)
    faces = result.faces

    const consoleErrors = session.getConsoleMessages().map(m => m.text)
    if (consoleErrors.length) {
      process.stderr.write(`[cube] console messages during render:\n  ${consoleErrors.join('\n  ')}\n`)
    }
  } finally {
    await session.teardown()
  }

  // Flip each face bottom-up → top-down (PNG row 0 = top), encode, write.
  for (let f = 0; f < 6; f++) {
    const { width, height, pixels } = faces[f]
    const topDown = Buffer.alloc(width * height * 4)
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const src = ((height - 1 - y) * width + x) * 4
        const dst = (y * width + x) * 4
        topDown[dst] = pixels[src]
        topDown[dst + 1] = pixels[src + 1]
        topDown[dst + 2] = pixels[src + 2]
        topDown[dst + 3] = pixels[src + 3]
      }
    }
    const png = encodePng(width, height, topDown)
    const outPath = join(opts.outDir, `${programName}.cube.golden_${FACE_NAMES[f]}.png`)
    writeFileSync(outPath, png)
    process.stderr.write(`[cube] wrote ${outPath} (${width}x${height})\n`)
  }
}

main().catch(err => {
  process.stderr.write(`[cube] FAILED: ${err?.stack || err?.message || JSON.stringify(err)}\n`)
  process.exit(1)
})
