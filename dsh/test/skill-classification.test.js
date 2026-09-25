/**
 * Skill classification contract for the DSH bundle.
 *
 * The distribution ships two kinds of directory under `skills/`: real skill
 * bundles (`<name>/SKILL.md`) and shared contract documents that the Codex and
 * Claude flows read as documents. Only the bundles may reach a DSH catalog, and
 * each bundle's invocation policy decides whether a model may load it on its own.
 *
 * This file pins that classification so a frontmatter edit cannot silently move a
 * skill across the model-invocation boundary, and so the documentation table in
 * `dsh/SKILL_CLASSIFICATION.md` cannot drift from the shipped frontmatter.
 */

import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'
import {
  discoverDistributionSkills,
  distributionSkillsRoot,
  parseSkillFrontmatter,
} from '../lib/distribution-skills.js'
import { LEGACY_ROUTING_DOCS, LEGACY_SKILLS } from '../lib/deploy-skills.js'

const root = distributionSkillsRoot()

/** Every directory under `skills/` that carries a `SKILL.md`. */
function shippedBundles() {
  return readdirSync(root, { withFileTypes: true })
    .filter(entry => entry.isDirectory())
    .map(entry => ({ name: entry.name, path: join(root, entry.name, 'SKILL.md') }))
    .filter(entry => {
      try {
        return readFileSync(entry.path, 'utf8').length > 0
      } catch {
        return false
      }
    })
}

/**
 * The reviewed model-invocation decision for every shipped bundle except the
 * legacy installation step, written out rather than derived so that changing a
 * skill's reachability requires editing this table on purpose.
 *
 * `modelInvocable: false` means the model never loads the body on its own; a
 * human still reaches it by typing the skill's own invocation. That is the
 * correct posture for the workflow skills, whose procedures belong to the
 * Codex/Claude routing documents this bundle does not apply to DSH main.
 */
const REVIEWED_INVOCATION = Object.freeze({
  cowlick: { modelInvocable: false, userInvocable: true },
  dictionary: { modelInvocable: true, userInvocable: true },
  e2e: { modelInvocable: false, userInvocable: true },
  meeting: { modelInvocable: false, userInvocable: true },
  polish: { modelInvocable: false, userInvocable: true },
  ponytail: { modelInvocable: false, userInvocable: true },
  preflight: { modelInvocable: true, userInvocable: false },
  rebase: { modelInvocable: false, userInvocable: true },
  tdd: { modelInvocable: true, userInvocable: true },
  unwind: { modelInvocable: false, userInvocable: true },
})

test('every shipped bundle parses and its frontmatter name equals its directory', () => {
  const bundles = shippedBundles()
  assert.ok(bundles.length > 0, 'the bundle ships no skill directory at all')
  for (const bundle of bundles) {
    const parsed = parseSkillFrontmatter(readFileSync(bundle.path, 'utf8'))
    assert.notEqual(parsed, undefined, `skills/${bundle.name}/SKILL.md has frontmatter DSH would drop`)
    assert.equal(parsed.name, bundle.name,
      `skills/${bundle.name}/SKILL.md declares name "${parsed.name}"`)
  }
})

test('the legacy installation step is the only bundle excluded from the DSH catalog', () => {
  const published = discoverDistributionSkills(root).map(candidate => candidate.name)
  const shipped = shippedBundles().map(bundle => bundle.name)
  assert.deepEqual(
    [...published].sort(),
    shipped.filter(name => !LEGACY_SKILLS.includes(name)).sort(),
    'a shipped bundle is missing from the catalog, or an unpublished one reached it',
  )
})

test('every published bundle keeps its reviewed model-invocation decision', () => {
  const catalog = new Map(
    discoverDistributionSkills(root).map(candidate => [candidate.name, candidate.invocation]),
  )
  assert.deepEqual(
    [...catalog.keys()].sort(),
    Object.keys(REVIEWED_INVOCATION).sort(),
    'the catalog no longer matches the reviewed skill table',
  )
  for (const [name, expected] of Object.entries(REVIEWED_INVOCATION)) {
    const found = catalog.get(name)
    assert.equal(found.modelInvocable, expected.modelInvocable,
      `${name} modelInvocable=${String(found.modelInvocable)}, reviewed ${String(expected.modelInvocable)}`)
    assert.equal(found.userInvocable, expected.userInvocable,
      `${name} userInvocable=${String(found.userInvocable)}, reviewed ${String(expected.userInvocable)}`)
  }
})

test('no repository-routing document is published as a skill', () => {
  const published = new Set(discoverDistributionSkills(root).map(candidate => candidate.name))
  for (const doc of LEGACY_ROUTING_DOCS) {
    const stem = doc.replace(/\.md$/, '').toLowerCase().replaceAll('_', '-')
    assert.equal(published.has(stem), false, `${doc} would be published as the skill "${stem}"`)
  }
})

test('every bundle and routing document is classified in SKILL_CLASSIFICATION.md', () => {
  const document = readFileSync(join(root, '..', 'SKILL_CLASSIFICATION.md'), 'utf8')
  for (const bundle of shippedBundles()) {
    assert.ok(document.includes(`\`${bundle.name}\``),
      `skills/${bundle.name} is not classified in dsh/SKILL_CLASSIFICATION.md`)
  }
  for (const doc of LEGACY_ROUTING_DOCS) {
    assert.ok(document.includes(`\`${doc}\``),
      `${doc} is not classified in dsh/SKILL_CLASSIFICATION.md`)
  }
})
