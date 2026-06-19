#!/usr/bin/env node
// gen-demo-dsl.mjs — generate the demo UI's ACTUAL default program for every
// effect in the manifest, by driving the live demo and reading the DSL that
// buildDslSource() produces (curated default params, special-cased pipelines).
//
// Usage: node gen-demo-dsl.mjs <outDir>
//   writes <outDir>/<ns>__<name>.dsl for every effect, plus a manifest TSV
//   "<ns>__<name>\t<dslPath>" to <outDir>/manifest.tsv
// Logs any effect whose program can't be generated.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const REFERENCE_ROOT = process.env.NM_REFERENCE_ROOT
  ? resolve(process.env.NM_REFERENCE_ROOT) : resolve(__dirname, '..', '..', 'noisemaker')
const HARNESS = join(REFERENCE_ROOT, 'vendor', 'shade-mcp', 'harness', 'index.js')
const MANIFEST = join(REFERENCE_ROOT, 'shaders', 'effects', 'manifest.json')
const STATUS_TIMEOUT = 300000

async function main () {
  const outDir = process.argv[2]
  if (!outDir) { process.stderr.write('usage: node gen-demo-dsl.mjs <outDir>\n'); process.exit(2) }
  mkdirSync(outDir, { recursive: true })

  const manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'))
  const effectIds = Object.keys(manifest).sort()

  process.env.SHADE_VIEWER_ROOT = REFERENCE_ROOT
  process.env.SHADE_VIEWER_PATH = '/demo/shaders/'
  process.env.SHADE_EFFECTS_DIR = join(REFERENCE_ROOT, 'shaders', 'effects')
  process.env.SHADE_GLOBALS_PREFIX = '__noisemaker'
  process.env.SHADE_HEADLESS = process.env.SHADE_HEADLESS ?? '1'

  const { BrowserSession } = await import(pathToFileURL(HARNESS).href)
  const session = new BrowserSession({ backend: 'webgl2' })
  const tsv = []
  let ok = 0, fail = 0
  try {
    await session.setup()
    const page = session.page
    await page.waitForFunction(
      () => !!window.__noisemakerCanvasRenderer && !!document.getElementById('effect-select'),
      { timeout: STATUS_TIMEOUT }
    )

    for (const id of effectIds) {
      const [ns, name] = id.split('/')
      const safe = `${ns}__${name}`
      try {
        // Drive the real selector change handler -> selectEffect() -> buildDslSource().
        // Reset the DSL marker first so we can detect the new program landing.
        await page.evaluate(() => { window.__noisemakerCurrentDsl = '__PENDING__' })
        await page.evaluate((effId) => {
          const sel = document.getElementById('effect-select')
          // Custom element dispatches detail.value; native dispatches target.value.
          sel.value = effId
          sel.dispatchEvent(new CustomEvent('change', { detail: { value: effId }, bubbles: true }))
        }, id)
        // Poll until buildDslSource has run for THIS effect (matches the proven probe path).
        let dsl = null
        for (let i = 0; i < 120; i++) {
          await new Promise(r => setTimeout(r, 250))
          const s = await page.evaluate((effId) => {
            const cur = window.__noisemakerCurrentEffect
            const d = window.__noisemakerCurrentDsl
            const ce = `${cur?.namespace}/${cur?.name}`
            if (ce !== effId) return null
            if (!d || d === '__PENDING__' || d.length === 0) return null
            return d
          }, id)
          if (s) { dsl = s; break }
        }
        if (!dsl) throw new Error('timeout waiting for generated DSL')

        const dslPath = join(outDir, `${safe}.dsl`)
        writeFileSync(dslPath, dsl.endsWith('\n') ? dsl : dsl + '\n')
        tsv.push(`${safe}\t${dslPath}`)
        process.stdout.write(`OK ${id}\n`)
        ok++
      } catch (e) {
        process.stderr.write(`GEN-FAIL ${id}: ${e?.message || e}\n`)
        fail++
      }
    }
  } finally {
    await session.teardown()
  }
  writeFileSync(join(outDir, 'manifest.tsv'), tsv.join('\n') + '\n')
  process.stdout.write(`[gen-demo-dsl] ${ok} ok, ${fail} fail; manifest -> ${join(outDir, 'manifest.tsv')}\n`)
}
main().catch(e => { process.stderr.write(`[gen-demo-dsl] FATAL ${e?.stack || e}\n`); process.exit(1) })
