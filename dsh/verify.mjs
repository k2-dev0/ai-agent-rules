import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(fileURLToPath(import.meta.url))
const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'))
const patch = readFileSync(join(root, 'cordis.patch.yml'), 'utf8')
const version = readFileSync(join(root, '.dsh-version'), 'utf8').trim()

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
  'name: \'@kaikojima/dsh-main-policy\'',
  '- dshMainPolicy',
  'absoluteStop: 200',
]) {
  assert.ok(patch.includes(expected), `missing patch contract: ${expected}`)
}

for (const forbidden of [
  /sk-[A-Za-z0-9_-]{16,}/,
  /AIza[0-9A-Za-z_-]{20,}/,
  /(?:api[_-]?key|token)\s*:\s*[^A-Z\s][^\s]*/i,
]) {
  assert.equal(forbidden.test(patch), false, `possible secret in patch: ${forbidden}`)
}

const tests = spawnSync(process.execPath, ['--test', 'test/*.test.js'], {
  cwd: root,
  encoding: 'utf8',
  shell: true,
})
process.stdout.write(tests.stdout)
process.stderr.write(tests.stderr)
if (tests.status !== 0) process.exit(tests.status ?? 1)

console.log('DSH bundle static verification passed')
