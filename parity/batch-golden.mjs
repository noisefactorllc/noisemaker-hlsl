#!/usr/bin/env node
// batch-golden.mjs — render MANY golden frames in ONE browser session.
//
// Like export-and-render.mjs but loops over a manifest, reusing a single
// BrowserSession (avoids a ~10s Chromium launch per program). For each program it
// exports the normalized graph.json (via tools/export-graph.mjs) and renders the
// reference GPU output to <name>.golden.png at a fixed size/time.
//
// Usage:
//   node batch-golden.mjs <manifest> <outDir> [--size 256] [--time 0.25] [--backend webgl2]
// manifest: each non-empty line is "<name>\t<dslPath>" (\t or whitespace).
//
// See parity/export-and-render.mjs for the per-program driving rationale.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { deflateSync } from 'node:zlib'

const __dirname = dirname(fileURLToPath(import.meta.url))
// Reference (golden) engine lives in the sibling `noisemaker` repo. Override
// with NM_REFERENCE_ROOT if it's elsewhere. (This repo was split out of
// noisemaker/noisemaker-hlsl/, where the default was just `../..`.)
const REFERENCE_ROOT = process.env.NM_REFERENCE_ROOT
  ? resolve(process.env.NM_REFERENCE_ROOT) : resolve(__dirname, '..', '..', 'noisemaker')
const HARNESS = join(REFERENCE_ROOT, 'vendor', 'shade-mcp', 'harness', 'index.js')
const EXPORT_GRAPH = join(__dirname, '..', 'tools', 'export-graph.mjs')
const STATUS_TIMEOUT = 300000

function crc32 (buf) { let c = 0xffffffff; for (let i = 0; i < buf.length; i++) { c ^= buf[i]; for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1) } return (c ^ 0xffffffff) >>> 0 }
function pngChunk (type, data) { const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0); const body = Buffer.concat([Buffer.from(type, 'ascii'), data]); const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body), 0); return Buffer.concat([len, body, crc]) }
function encodePng (w, h, rgba) { const sig = Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]); const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w,0); ihdr.writeUInt32BE(h,4); ihdr[8]=8; ihdr[9]=6; const raw = Buffer.alloc(h*(1+w*4)); for (let y=0;y<h;y++){ const di=y*(1+w*4); raw[di]=0; rgba.copy(raw, di+1, y*w*4, (y+1)*w*4) } return Buffer.concat([sig, pngChunk('IHDR', ihdr), pngChunk('IDAT', deflateSync(raw)), pngChunk('IEND', Buffer.alloc(0))]) }

function parseArgs (argv) {
  const o = { size: 256, time: 0.25, backend: 'webgl2' }; const pos = []
  for (let i = 0; i < argv.length; i++) { const a = argv[i]
    if (a === '--size') o.size = parseInt(argv[++i], 10)
    else if (a === '--time') o.time = parseFloat(argv[++i])
    else if (a === '--backend') o.backend = argv[++i]
    else pos.push(a) }
  o.manifest = pos[0]; o.outDir = pos[1]; return o
}

// Drive the demo to load one DSL and read back o0 as linear-quantised RGBA8 top-down.
async function renderOne (page, dsl, size, time, lastId) {
  const baselineId = lastId
  await page.evaluate((src) => {
    const ed = document.getElementById('dsl-editor'); const run = document.getElementById('dsl-run-btn')
    ed.value = src; ed.dispatchEvent(new Event('input', { bubbles: true })); run.click()
  }, dsl)
  await page.waitForFunction((base) => {
    const s = (document.getElementById('status')?.textContent || '').toLowerCase()
    if (s.includes('error') || s.includes('failed')) throw new Error('DSL compile failed: ' + document.getElementById('status')?.textContent)
    const p = window.__noisemakerRenderingPipeline
    return !!(p && p.graph && p.graph.id !== base)
  }, { timeout: STATUS_TIMEOUT }, baselineId)
  await page.evaluate(() => { if (window.__noisemakerSetPaused) window.__noisemakerSetPaused(true) })
  await page.evaluate((sz) => {
    const r = window.__noisemakerCanvasRenderer; const p = window.__noisemakerRenderingPipeline
    if (r && r.canvas) { r.canvas.width = sz; r.canvas.height = sz; if (r.canvas.style){ r.canvas.style.width = sz+'px'; r.canvas.style.height = sz+'px' } }
    if (p && typeof p.resize === 'function') p.resize(sz, sz)
  }, size)
  await page.evaluate(({ t, frames }) => {
    if (window.__noisemakerSetPausedTime) window.__noisemakerSetPausedTime(t)
    const p = window.__noisemakerRenderingPipeline; const r = window.__noisemakerCanvasRenderer
    for (let i = 0; i < frames; i++) { if (p && p.render) p.render(t); else if (r && r.render) r.render(t) }
  }, { t: time, frames: 8 })
  const result = await page.evaluate(() => {
    const pipeline = window.__noisemakerRenderingPipeline
    const gl = pipeline?.backend?.gl
    const surface = pipeline?.surfaces?.get(pipeline?.graph?.renderSurface || 'o0')
    if (!gl || !surface) return { error: 'no GL surface' }
    const info = pipeline.backend.textures?.get(surface.read)
    if (!info?.handle) return { error: 'no texture handle' }
    const { handle, width, height, glFormat } = info
    const fbo = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, fbo)
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, handle, 0)
    if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) { gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.deleteFramebuffer(fbo); return { error: 'FBO incomplete' } }
    const canFloat = !!(gl.getExtension('EXT_color_buffer_float') || gl.getExtension('WEBGL_color_buffer_float'))
    const isFloat = glFormat?.type === gl.HALF_FLOAT || glFormat?.type === gl.FLOAT
    gl.finish(); let rgba8
    if (isFloat && canFloat) { const buf = new Float32Array(width*height*4); gl.readPixels(0,0,width,height,gl.RGBA,gl.FLOAT,buf); rgba8 = new Array(width*height*4); for (let i=0;i<buf.length;i++) rgba8[i]=Math.max(0,Math.min(255,Math.round(buf[i]*255))) }
    else { const buf = new Uint8Array(width*height*4); gl.readPixels(0,0,width,height,gl.RGBA,gl.UNSIGNED_BYTE,buf); rgba8 = Array.from(buf) }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.deleteFramebuffer(fbo)
    return { width, height, pixels: rgba8, graphId: pipeline.graph.id }
  })
  if (result.error) throw new Error('readback: ' + result.error)
  const { width, height, pixels } = result
  const topDown = Buffer.alloc(width*height*4)
  for (let y=0;y<height;y++) for (let x=0;x<width;x++) { const s=((height-1-y)*width+x)*4, d=(y*width+x)*4; topDown[d]=pixels[s]; topDown[d+1]=pixels[s+1]; topDown[d+2]=pixels[s+2]; topDown[d+3]=pixels[s+3] }
  return { png: encodePng(width, height, topDown), graphId: result.graphId }
}

async function main () {
  const o = parseArgs(process.argv.slice(2))
  if (!o.manifest || !o.outDir) { process.stderr.write('usage: node batch-golden.mjs <manifest> <outDir> [--size N] [--time T]\n'); process.exit(2) }
  mkdirSync(o.outDir, { recursive: true })
  const items = readFileSync(o.manifest, 'utf8').split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'))
    .map(l => { const p = l.split(/\s+/); return { name: p[0], dslPath: p[1] } })

  const { exportGraph } = await import(pathToFileURL(EXPORT_GRAPH).href)

  process.env.SHADE_VIEWER_ROOT = REFERENCE_ROOT
  process.env.SHADE_VIEWER_PATH = '/demo/shaders/'
  process.env.SHADE_EFFECTS_DIR = join(REFERENCE_ROOT, 'shaders', 'effects')
  process.env.SHADE_GLOBALS_PREFIX = '__noisemaker'
  process.env.SHADE_HEADLESS = process.env.SHADE_HEADLESS ?? '1'
  const { BrowserSession } = await import(pathToFileURL(HARNESS).href)
  const session = new BrowserSession({ backend: o.backend })
  let ok = 0, fail = 0
  try {
    await session.setup(); const page = session.page; await session.setBackend(o.backend)
    await page.setViewportSize({ width: o.size, height: o.size })
    await page.waitForFunction(() => !!window.__noisemakerRenderingPipeline && !!document.getElementById('dsl-editor'), { timeout: STATUS_TIMEOUT })
    let lastId = await page.evaluate(() => window.__noisemakerRenderingPipeline?.graph?.id ?? null)
    let firstItem = true
    for (const it of items) {
      try {
        // DETERMINISM: a reused browser session leaks uninitialized GPU texture
        // content from the previous effect into the next. Stateless effects that
        // sample an uncleared internal/feedback buffer (e.g. moodscape, fractal,
        // shape, kaleido) then render ORDER-DEPENDENT output — the golden depends
        // on what was drawn before it, not just the effect. Reloading the page
        // between effects drops the WebGL context so every effect renders from a
        // clean (zero-initialized) texture state, matching the port's per-effect
        // isolation (NMParityRunner renders each graph fresh). The first effect
        // already starts clean from session.setup, so only reload thereafter.
        if (!firstItem) {
          await page.reload({ waitUntil: 'load' })
          await page.waitForFunction(() => !!window.__noisemakerRenderingPipeline && !!document.getElementById('dsl-editor'), { timeout: STATUS_TIMEOUT })
          await page.setViewportSize({ width: o.size, height: o.size })
          lastId = await page.evaluate(() => window.__noisemakerRenderingPipeline?.graph?.id ?? null)
        }
        firstItem = false
        const dsl = readFileSync(it.dslPath, 'utf8')
        // graph.json (no browser needed; uses the reference compiler).
        try { const g = await exportGraph(dsl); writeFileSync(join(o.outDir, `${it.name}.graph.json`), JSON.stringify(g, null, 2) + '\n') }
        catch (e) { process.stderr.write(`[batch] ${it.name} GRAPH-FAIL ${e?.message || e}\n`); fail++; continue }
        const { png, graphId } = await renderOne(page, dsl, o.size, o.time, lastId)
        lastId = graphId
        writeFileSync(join(o.outDir, `${it.name}.golden.png`), png)
        process.stdout.write(`OK ${it.name}\n`); ok++
      } catch (e) { process.stderr.write(`[batch] ${it.name} GOLDEN-FAIL ${e?.message || e}\n`); fail++ }
    }
  } finally { await session.teardown() }
  process.stdout.write(`[batch-golden] ${ok} ok, ${fail} fail\n`)
}
main().catch(e => { process.stderr.write(`[batch-golden] FATAL ${e?.stack || e}\n`); process.exit(1) })
