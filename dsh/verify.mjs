/**
 * `npm run verify` for the DSH main bundle.
 *
 * Two phases:
 * 1. static checks over the bundle declarations and the unit suite
 * 2. the real end-to-end run against an installed DSH `0.1.7-rc.1`
 *
 * The E2E phase uses a throwaway DSH home, a throwaway Git workspace, and a
 * loopback mock provider, so it never contacts a real provider and never bills
 * an account. `npm run verify` always runs both phases; there is no mode that
 * silently skips the end-to-end half.
 */

import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const root = dirname(fileURLToPath(import.meta.url))
const env = process.env
const runE2E = env.DSH_VERIFY_NO_E2E !== '1'
const onlyE2E = env.DSH_VERIFY_E2E_ONLY === '1'

const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
const patch = readFileSync(join(root, 'cordis.patch.yml'), 'utf8')
const index = readFileSync(join(root, 'index.js'), 'utf8')
const version = readFileSync(join(root, '.dsh-version'), 'utf8').trim()
const packageManifest = manifest

function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, encoding: 'utf8', shell: false, env })
  process.stdout.write(result.stdout ?? '')
  process.stderr.write(result.stderr ?? '')
  return result.status ?? 1
}

if (!onlyE2E) {
  assert.equal(version, '0.1.7-rc.1')
  assert.equal(manifest.dsh.bundle.patch, './cordis.patch.yml')

  for (const expected of [
    'provider: deepseek-official',
    'model: deepseek-flash',
    'toolName: external_research_design',
    'toolName: external_opus_design',
    'toolName: external_code',
    'toolName: review_change',
    'model: glm-5.3',
    'model: claude-opus-5-5',
    'model: gpt-6-sol',
    'maxDepth: 1',
    "name: '@kaikojima/dsh-main-policy'",
    '- dshMainPolicy',
    // Routing intent states are rejected, not written, by every external tool.
    'stateRoot:',
  ]) {
    assert.ok(patch.includes(expected), `missing patch contract: ${expected}`)
  }

  // The distribution owns its skill provider in code. A YAML-configured
  // filesystem root cannot exist in an installed profile, so its absence is part
  // of the contract rather than an omission.
  assert.equal(patch.includes('dsh-main-skill-filesystem'), false,
    'the bundle must not point a YAML-configured filesystem provider at a path')
  for (const required of [
    "import { registerDistributionSkills } from './lib/distribution-skills.js'",
    'registerDistributionSkills(ctx)',
    "'skills'",
  ]) {
    assert.ok(index.includes(required), `missing provider wiring in index.js: ${required}`)
  }
  assert.equal(index.includes('dsh-main-skill-filesystem'), false,
    'index.js must not reference the removed filesystem row')
  assert.ok(packageManifest.files.includes('skills'),
    'the bundle must ship its skills directory')
  for (const skill of ['tdd', 'unwind', 'preflight', 'meeting']) {
    assert.ok(existsSync(join(root, 'skills', skill, 'SKILL.md')),
      `the bundle must ship skills/${skill}/SKILL.md`)
  }

  // No budget, price, or spend concept may exist in this bundle.
  for (const forbidden of [
    /sk-[A-Za-z0-9_-]{16,}/,
    /AIza[0-9A-Za-z_-]{20,}/,
    /(?:api[_-]?key|token)\s*:\s*[^A-Z\s][^\s]*/i,
    /\b(?:budget|spend|cost|price|usd|billing|quota)\b/i,
  ]) {
    assert.equal(forbidden.test(patch), false, `forbidden content in patch: ${forbidden}`)
  }

  const status = run(process.execPath, ['--test', 'test/*.test.js'])
  if (status !== 0) process.exit(status)
  console.log('DSH bundle static verification passed')
}

if (runE2E) {
  console.log('running the DSH end-to-end verification')
  // Imported rather than spawned: a nested `node --test` invocation on this
  // platform completes with no output at all, which would report success for a
  // suite that never ran. Importing registers the end-to-end tests with the
  // runner that is already executing, so their failures reach this process.
  await import(pathToFileURL(join(root, 'test', 'e2e', 'workflows.test.js')).href)
}

console.log('DSH bundle verification passed')
