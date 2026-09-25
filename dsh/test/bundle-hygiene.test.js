/**
 * The bundle must not ship scratch.
 *
 * Development leaves temporary probes, relink helpers, and captured reports
 * beside the suite. `test/clean.mjs` removes them before the runner expands
 * `test/*.test.js`, because a file present at startup is loaded as a suite even
 * when a test later deletes it. This asserts the sweep actually happened, so a
 * dirty checkout cannot pass as a clean one.
 */

import assert from 'node:assert/strict'
import { existsSync, readdirSync, statSync } from 'node:fs'
import { join, relative } from 'node:path'
import test from 'node:test'
import { bundleRoot } from './e2e/harness.mjs'

/** Names that look temporary but are part of the bundle. None today. */
const KEEP = Object.freeze([])

/** The same pattern `test/clean.mjs` sweeps with. */
const SCRATCH = /^(?:zz[-.].*|.*\.(?:fresh|relink|rw)-\d+|.*\.(?:report|dump)\.(?:json|yml)|apply-[a-z-]+\.mjs|ZZ_.*\.md)$/

test('the bundle carries no scratch or captured file', () => {
  const found = []
  const walk = (dir) => {
    for (const entry of readdirSync(dir)) {
      if (entry === 'node_modules' || entry === '.git') continue
      const full = join(dir, entry)
      const label = relative(bundleRoot, full)
      if (KEEP.includes(label)) continue
      if (statSync(full).isDirectory()) {
        walk(full)
        continue
      }
      if (SCRATCH.test(entry)) found.push(label)
    }
  }
  walk(bundleRoot)
  assert.deepEqual(found, [], `the bundle carries scratch files: ${found.join(', ')}`)

  // Every published path must still be present.
  for (const entry of ['index.js', 'lib', 'skills', 'cordis.patch.yml', 'AGENTS.dsh.md']) {
    assert.ok(existsSync(join(bundleRoot, entry)), `the published entry ${entry} is missing`)
  }
})
