#!/usr/bin/env node
// cube-equirect-ref.mjs — REFERENCE equirectangular projection of a renderCubemap*
// program, the seamless "ground truth" for verifying Unity's cube-sampling.
//
// Renders the 6 reference cube faces (like cube-golden.mjs), then assembles an
// equirect by sampling them through the reference's OWN directionToFaceUV — i.e.
// exactly how the reference cube is meant to be sampled. By construction this is
// seamless; comparing the Unity equirect (NMParityRunner.RenderCubeEquirect, which
// uses Unity's HARDWARE cube sampler) against it reveals any seam / orientation
// mismatch in the assembled Unity TextureCube.
//
// Direction mapping (must match Shaders/Util/NMCubeEquirect.shader):
//   equirect pixel (ex,ey), top-down (ey=0 = top):
//     lon = ((ex+0.5)/W - 0.5) * 2*PI ;  lat = (0.5 - (ey+0.5)/H) * PI
//     dir = (cos(lat)sin(lon), sin(lat), cos(lat)cos(lon))
//   face pixel for dir -> (face,u,v) = directionToFaceUV(dir):
//     col = ((u+1)/2)*N - 0.5 ;  row = ((1+v)/2)*N - 0.5   (top-down face array)
//   (derived: shader ray rd = faceDirection(f, uv.x, -uv.y), so screen uv=(u,-v).)
//
// Usage:
//   node cube-equirect-ref.mjs <program.dsl> <outPng> [--time 0.25] [--size 256] \
//        [--eqw 512] [--eqh 256] [--backend webgl2]

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve, basename, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { deflateSync } from 'node:zlib'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REFERENCE_ROOT = process.env.NM_REFERENCE_ROOT
  ? resolve(process.env.NM_REFERENCE_ROOT)
  : resolve(__dirname, '..', '..', 'noisemaker')
const HARNESS = join(REFERENCE_ROOT, 'vendor', 'shade-mcp', 'harness', 'index.js')
const CUBE_CAMERA = join(REFERENCE_ROOT, 'shaders', 'src', 'renderer', 'cubeCamera.js')

function crc32 (buf) {
  let c = 0xffffffff
  for (let i = 0; i < buf.length; i++) { c ^= buf[i]; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1) }
  return (c ^ 0xffffffff) >>> 0
}
function pngChunk (type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0)
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data])
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body), 0)
  return Buffer.concat([len, body, crc])
}
function encodePng (width, height, rgbaTopDown) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0
  const raw = Buffer.alloc(height * (1 + width * 4))
  for (let y = 0; y < height; y++) { const di = y * (1 + width * 4); raw[di] = 0; rgbaTopDown.copy(raw, di + 1, y * width * 4, (y + 1) * width * 4) }
  return Buffer.concat([sig, pngChunk('IHDR', ihdr), pngChunk('IDAT', deflateSync(raw)), pngChunk('IEND', Buffer.alloc(0))])
}

// Bilinear sample a top-down RGBA8 face array (N x N) at float (col,row).
function sampleFace (arr, N, col, row) {
  col = Math.max(0, Math.min(N - 1, col)); row = Math.max(0, Math.min(N - 1, row))
  const x0 = Math.floor(col), y0 = Math.floor(row)
  const x1 = Math.min(N - 1, x0 + 1), y1 = Math.min(N - 1, y0 + 1)
  const fx = col - x0, fy = row - y0
  const out = [0, 0, 0, 0]
  for (let c = 0; c < 4; c++) {
    const p00 = arr[(y0 * N + x0) * 4 + c], p10 = arr[(y0 * N + x1) * 4 + c]
    const p01 = arr[(y1 * N + x0) * 4 + c], p11 = arr[(y1 * N + x1) * 4 + c]
    const a = p00 + (p10 - p00) * fx, b = p01 + (p11 - p01) * fx
    out[c] = Math.round(a + (b - a) * fy)
  }
  return out
}

const VIEWER_ROOT = REFERENCE_ROOT
const STATUS_TIMEOUT = 300000

function parseArgs (argv) {
  const opts = { time: 0.25, size: 256, eqw: 512, eqh: 256, backend: 'webgl2' }
  const pos = []
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--time') opts.time = parseFloat(argv[++i])
    else if (a === '--size') opts.size = parseInt(argv[++i], 10)
    else if (a === '--eqw') opts.eqw = parseInt(argv[++i], 10)
    else if (a === '--eqh') opts.eqh = parseInt(argv[++i], 10)
    else if (a === '--backend') opts.backend = argv[++i]
    else pos.push(a)
  }
  opts.programPath = pos[0]; opts.outPng = pos[1]
  return opts
}

async function main () {
  const opts = parseArgs(process.argv.slice(2))
  if (!opts.programPath || !opts.outPng) {
    process.stderr.write('usage: node cube-equirect-ref.mjs <program.dsl> <outPng> [--time t] [--size N] [--eqw W] [--eqh H]\n')
    process.exit(2)
  }
  const dsl = readFileSync(opts.programPath, 'utf8')
  mkdirSync(dirname(resolve(opts.outPng)), { recursive: true })

  const { CUBE_FACE_BASES, directionToFaceUV } = await import(pathToFileURL(CUBE_CAMERA).href)
  const bases = CUBE_FACE_BASES.map(b => Array.from(b))

  process.env.SHADE_VIEWER_ROOT = VIEWER_ROOT
  process.env.SHADE_VIEWER_PATH = '/demo/shaders/'
  process.env.SHADE_EFFECTS_DIR = join(REFERENCE_ROOT, 'shaders', 'effects')
  process.env.SHADE_GLOBALS_PREFIX = '__noisemaker'
  process.env.SHADE_HEADLESS = process.env.SHADE_HEADLESS ?? '1'

  const { BrowserSession } = await import(pathToFileURL(HARNESS).href)
  const session = new BrowserSession({ backend: opts.backend })
  let faces
  try {
    await session.setup()
    const page = session.page
    await session.setBackend(opts.backend)
    const globals = session.globals
    await page.setViewportSize({ width: opts.size, height: opts.size })
    await page.waitForFunction(() => !!window.__noisemakerRenderingPipeline &&
      !!document.getElementById('dsl-editor') && !!document.getElementById('dsl-run-btn'), { timeout: STATUS_TIMEOUT })
    const baselineId = await page.evaluate(() => window.__noisemakerRenderingPipeline?.graph?.id ?? null)
    await page.evaluate((src) => {
      const editor = document.getElementById('dsl-editor'); const runBtn = document.getElementById('dsl-run-btn')
      editor.value = src; editor.dispatchEvent(new Event('input', { bubbles: true })); runBtn.click()
    }, dsl)
    await page.waitForFunction((base) => {
      const s = (document.getElementById('status')?.textContent || '').toLowerCase()
      if (s.includes('error') || s.includes('failed')) throw new Error('DSL compile failed: ' + document.getElementById('status')?.textContent)
      const p = window.__noisemakerRenderingPipeline
      return !!(p && p.graph && p.graph.id !== base)
    }, { timeout: STATUS_TIMEOUT }, baselineId)
    await page.evaluate(() => { if (window.__noisemakerSetPaused) window.__noisemakerSetPaused(true) })
    await page.evaluate((size) => {
      const r = window.__noisemakerCanvasRenderer; const p = window.__noisemakerRenderingPipeline
      if (r && r.canvas) { r.canvas.width = size; r.canvas.height = size; if (r.canvas.style) { r.canvas.style.width = size + 'px'; r.canvas.style.height = size + 'px' } }
      if (p && typeof p.resize === 'function') p.resize(size, size)
    }, opts.size)

    const result = await page.evaluate(({ g, bases, time, frames }) => {
      const pipeline = window[g.renderingPipeline]; const backend = pipeline?.backend; const gl = backend?.gl
      if (!gl) return { status: 'error', error: 'no GL' }
      if (window.__noisemakerSetPausedTime) window.__noisemakerSetPausedTime(time)
      function readO0 () {
        const surface = pipeline.surfaces?.get(pipeline.graph?.renderSurface || 'o0')
        const info = backend.textures?.get(surface.read); if (!info?.handle) return null
        const { handle, width, height, glFormat } = info
        const fbo = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, fbo)
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, handle, 0)
        const canFloat = !!(gl.getExtension('EXT_color_buffer_float') || gl.getExtension('WEBGL_color_buffer_float'))
        const isFloat = glFormat?.type === gl.HALF_FLOAT || glFormat?.type === gl.FLOAT
        gl.finish()
        let rgba8
        if (isFloat && canFloat) {
          const buf = new Float32Array(width * height * 4); gl.readPixels(0, 0, width, height, gl.RGBA, gl.FLOAT, buf)
          rgba8 = new Array(width * height * 4); for (let i = 0; i < buf.length; i++) rgba8[i] = Math.max(0, Math.min(255, Math.round(buf[i] * 255)))
        } else {
          const buf = new Uint8Array(width * height * 4); gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, buf); rgba8 = Array.from(buf)
        }
        gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.deleteFramebuffer(fbo)
        return { width, height, pixels: rgba8 }
      }
      const out = []
      for (let f = 0; f < 6; f++) {
        pipeline.setUniform('cubeBasis', bases[f])
        for (let i = 0; i < frames; i++) pipeline.render(time)
        const r = readO0(); if (!r) return { status: 'error', error: 'face ' + f }
        out.push(r)
      }
      return { status: 'ok', faces: out }
    }, { g: globals, bases, time: opts.time, frames: 8 })
    if (result.status === 'error') throw new Error(result.error)
    faces = result.faces
  } finally {
    await session.teardown()
  }

  const N = opts.size
  // Flip each face to top-down (PNG/array row 0 = top), matching cube-golden.
  const facesTD = faces.map(({ width, height, pixels }) => {
    const td = new Array(width * height * 4)
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const s = ((height - 1 - y) * width + x) * 4, d = (y * width + x) * 4
      td[d] = pixels[s]; td[d + 1] = pixels[s + 1]; td[d + 2] = pixels[s + 2]; td[d + 3] = pixels[s + 3]
    }
    return td
  })

  const W = opts.eqw, H = opts.eqh
  const eq = Buffer.alloc(W * H * 4)
  for (let ey = 0; ey < H; ey++) {
    for (let ex = 0; ex < W; ex++) {
      const lon = ((ex + 0.5) / W - 0.5) * 2 * Math.PI
      const lat = (0.5 - (ey + 0.5) / H) * Math.PI
      const cl = Math.cos(lat)
      const d = [cl * Math.sin(lon), Math.sin(lat), cl * Math.cos(lon)]
      const { face, u, v } = directionToFaceUV(d)
      const col = ((u + 1) / 2) * N - 0.5
      const row = ((1 + v) / 2) * N - 0.5
      const c = sampleFace(facesTD[face], N, col, row)
      const di = (ey * W + ex) * 4
      eq[di] = c[0]; eq[di + 1] = c[1]; eq[di + 2] = c[2]; eq[di + 3] = c[3]
    }
  }
  writeFileSync(resolve(opts.outPng), encodePng(W, H, eq))
  process.stderr.write(`[equirect-ref] wrote ${opts.outPng} (${W}x${H})\n`)
}

main().catch(err => { process.stderr.write(`[equirect-ref] FAILED: ${err?.stack || err?.message || err}\n`); process.exit(1) })
