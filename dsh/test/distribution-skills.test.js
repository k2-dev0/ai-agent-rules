import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, mkdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import test from 'node:test'
import {
  PROVIDER_NAME,
  discoverDistributionSkills,
  distributionSkillsRoot,
  parseSkillFrontmatter,
  registerDistributionSkills,
} from '../lib/distribution-skills.js'

test('the distribution skill root resolves inside the bundle that ships the skills', () => {
  const root = distributionSkillsRoot()
  assert.equal(existsSync(root), true, `resolved root does not exist: ${root}`)
  assert.equal(existsSync(join(root, 'tdd', 'SKILL.md')), true, `tdd/SKILL.md missing under ${root}`)
  // The root must live in the bundle itself: a path outside it would not exist
  // once the bundle is installed into a profile.
  assert.match(root, /dsh[/\\]skills$/)
})

test('only directory bundles become candidates and contract docs are ignored', () => {
  const candidates = discoverDistributionSkills(distributionSkillsRoot())
  const names = candidates.map(candidate => candidate.name).sort()
  assert.ok(names.includes('tdd'), `tdd missing from ${JSON.stringify(names)}`)
  assert.ok(names.includes('unwind'), `unwind missing from ${JSON.stringify(names)}`)
  assert.equal(names.includes('WORKFLOW_ROUTING'), false)
  for (const candidate of candidates) {
    assert.equal(candidate.provider, PROVIDER_NAME)
    assert.equal(candidate.source, 'bundled')
    assert.equal(candidate.path.endsWith(join(candidate.name, 'SKILL.md')), true)
    assert.equal(typeof candidate.invocation.modelInvocable, 'boolean')
    assert.equal(typeof candidate.invocation.userInvocable, 'boolean')
  }
})

test('frontmatter invocation booleans are strict and malformed entries are dropped', () => {
  const ok = parseSkillFrontmatter('---\nname: tdd\ndescription: "d"\ndisable-model-invocation: true\n---\nbody\n')
  assert.equal(ok.name, 'tdd')
  assert.equal(ok.invocation.modelInvocable, false)
  assert.equal(ok.invocation.userInvocable, true)

  const userOnly = parseSkillFrontmatter('---\nname: preflight\ndescription: d\nuser-invocable: false\n---\n')
  assert.equal(userOnly.invocation.userInvocable, false)

  for (const bad of [
    'no frontmatter at all',
    '---\ndescription: d\n---\n',
    '---\nname: Not-Kebab\ndescription: d\n---\n',
    '---\nname: tdd\n---\n',
    '---\nname: tdd\ndescription: d\ndisable-model-invocation: maybe\n---\n',
  ]) {
    assert.equal(parseSkillFrontmatter(bad), undefined, `should have been rejected: ${bad}`)
  }
})

test('the provider lists candidates and loads a body without frontmatter', async () => {
  const registered = []
  const ctx = { skills: { registerProvider: (create) => { registered.push(create({ signal: new AbortController().signal, invalidate() {} })); return () => {} } } }
  registerDistributionSkills(ctx)
  assert.equal(registered.length, 1)
  const provider = registered[0]
  assert.equal(provider.name, PROVIDER_NAME)

  const candidates = await provider.list({ cwd: process.cwd() })
  const tdd = candidates.find(candidate => candidate.name === 'tdd')
  assert.ok(tdd, 'tdd was not listed')

  const definition = await provider.get(tdd, { cwd: process.cwd() })
  assert.ok(definition, 'tdd body did not load')
  assert.equal(definition.name, 'tdd')
  assert.equal(definition.content.startsWith('---'), false, 'frontmatter must be stripped from the body')
  assert.ok(definition.content.length > 0)

  const stale = await provider.get({ ...tdd, name: 'renamed' }, { cwd: process.cwd() })
  assert.equal(stale, undefined, 'a stale selection must not load')
})

test('an empty or missing root yields no candidates instead of throwing', () => {
  const empty = mkdtempSync(join(tmpdir(), 'dsh-skills-empty-'))
  assert.deepEqual(discoverDistributionSkills(empty), [])
  assert.deepEqual(discoverDistributionSkills(join(empty, 'missing')), [])

  const root = mkdtempSync(join(tmpdir(), 'dsh-skills-bad-'))
  mkdirSync(join(root, 'broken'))
  writeFileSync(join(root, 'broken', 'SKILL.md'), 'no frontmatter\n')
  mkdirSync(join(root, 'mismatch'))
  writeFileSync(join(root, 'mismatch', 'SKILL.md'), '---\nname: other\ndescription: d\n---\n')
  assert.deepEqual(discoverDistributionSkills(root), [])
  void resolve
})
