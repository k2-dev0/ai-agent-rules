/**
 * Remove scratch files this bundle must never carry.
 *
 * Development leaves temporary probes, relink helpers, and captured reports
 * beside the suite, and `node --test test/*.test.js` expands that glob before any
 * test runs — so a scratch file present at startup is loaded as a suite even
 * when a test removes it. Cleaning it first is what keeps the published set
 * exactly what `package.json` declares.
 *
 * Runs as `pretest`, so `npm test` and `npm run verify` both start clean.
 */

import { readdirSync, rmSync, statSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const bundleRoot = join(here, '..')

/** Names that look temporary but are part of the bundle. None today. */
const KEEP = new Set()

/**
 * A scratch name: a `zz` probe, a `.fresh`/`.relink`/`.rw` copy, a captured
 * report or dump, or a one-off maintenance script. Narrow on purpose, so a real
 * file cannot match by accident.
 */
const SCRATCH = /^(?:zz[-.].*|.*\.(?:fresh|relink|rw)-\d+|.*\.(?:report|dump)\.(?:json|yml)|apply-[a-z-]+\.mjs|ZZ_.*\.md)$/

/**
 * Remove every scratch file under the bundle.
 *
 * @param root - the bundle directory to sweep.
 * @returns the bundle-relative paths that were removed.
 */
export function cleanScratch(root = bundleRoot) {
  const removed = []
  const walk = (dir) => {
    for (const entry of readdirSync(dir)) {
      if (entry === 'node_modules' || entry === '.git') continue
      const full = join(dir, entry)
      const label = relative(root, full)
      if (KEEP.has(label)) continue
      const metadata = statSync(full)
      if (metadata.isDirectory()) {
        walk(full)
        continue
      }
      if (!SCRATCH.test(entry)) continue
      rmSync(full, { force: true })
      removed.push(label)
    }
  }
  walk(root)
  return removed
}

// Importable from the verifier, runnable as `pretest`.
if (process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const removed = cleanScratch()
  if (removed.length > 0) {
    process.stderr.write(`[bundle] removed scratch file(s): ${removed.join(', ')}\n`)
  }
}

