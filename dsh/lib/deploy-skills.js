/**
 * Deploy the distribution's skills into a DSH-discovered skill root.
 *
 * DSH's filesystem skill provider scans `<projectRoot>/.dsh/skills` and
 * `<projectRoot>/.agents/skills` with no extra configuration, one level deep,
 * and only for `<name>/SKILL.md` bundles. The distribution keeps its skills in
 * flat directories under `skills/`, alongside shared contract documents that are
 * not skills, so a plain copy of `skills/` would publish the contract documents
 * as skills.
 *
 * This module therefore selects only the actual skill bundles (a directory that
 * contains `SKILL.md`), validates the DSH frontmatter contract before copying,
 * and removes bundles it previously deployed so a deleted skill disappears from
 * the catalog. It is idempotent and never touches files it did not deploy.
 */

import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { join, resolve } from 'node:path'

/** Frontmatter values that DSH accepts as booleans, matching its own grammar. */
const TRUE_VALUES = new Set(['true', 'yes', 'on', '1'])
const FALSE_VALUES = new Set(['false', 'no', 'off', '0'])

const MARKER = '.dsh-skills-manifest.json'

/**
 * Skill directories that stay Codex/Claude-only.
 *
 * `bootstrap` resolves the distribution placeholders and self-deletes after it
 * runs, which is a legacy-installation step with no DSH equivalent.
 */
export const LEGACY_SKILLS = Object.freeze(['bootstrap'])

/**
 * Shared contract documents that live beside the skills.
 *
 * They are read as documents by the Claude/Codex flows, not loaded as skills;
 * publishing them into a DSH skill root would advertise them as skills.
 */
export const LEGACY_ROUTING_DOCS = Object.freeze([
  'CHILD_RULES.md',
  'CODE_REVIEW_CONTRACT.md',
  'DEEPSEEK_WORKFLOW.md',
  'DIFFICULTY_CONTRACT.md',
  'FIX_FLOW.md',
  'IMPLEMENTATION_RULES.md',
  'INDEPENDENT_REVIEW.md',
  'MODEL_SELECTION.md',
  'MODEL_SWITCH.md',
  'REVIEW_SEVERITY.md',
  'SUBAGENT_RULES.md',
  'WORKFLOW_ROUTING.md',
])

function parseScalar(raw) {
  const value = raw.trim()
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    return value.slice(1, -1)
  }
  if (value === '') return undefined
  return value
}

/**
 * Parse the leading YAML frontmatter with the small subset DSH reads.
 *
 * Only top-level scalars and the two invocation keys matter here, so a full YAML
 * parser would add a dependency for no gain. Anything malformed is reported so
 * deployment fails loudly instead of publishing a skill DSH would silently drop.
 */
export function parseSkillFrontmatter(text, label) {
  const match = String(text).match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/)
  if (!match) throw new Error(`${label}: SKILL.md must start with YAML frontmatter`)
  const fields = new Map()
  let currentKey
  for (const line of match[1].split(/\r?\n/)) {
    if (line.trim() === '' || line.trimStart().startsWith('#')) continue
    const entry = line.match(/^([A-Za-z][A-Za-z0-9_-]*):(?:\s*(.*))?$/)
    if (entry) {
      currentKey = entry[1]
      fields.set(currentKey, parseScalar(entry[2] ?? ''))
      continue
    }
    // A nested or list continuation belongs to the previous key and is ignored.
    if (currentKey === undefined) throw new Error(`${label}: frontmatter has a value before any key`)
  }
  const name = fields.get('name')
  const description = fields.get('description')
  if (typeof name !== 'string' || name === '') throw new Error(`${label}: frontmatter requires name`)
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name)) {
    throw new Error(`${label}: frontmatter name "${name}" is not kebab-case as DSH requires`)
  }
  if (typeof description !== 'string' || description === '') {
    throw new Error(`${label}: frontmatter requires description`)
  }
  const invocation = {}
  for (const key of ['disable-model-invocation', 'user-invocable']) {
    if (!fields.has(key)) continue
    const raw = String(fields.get(key)).toLowerCase()
    if (TRUE_VALUES.has(raw)) invocation[key] = true
    else if (FALSE_VALUES.has(raw)) invocation[key] = false
    else throw new Error(`${label}: frontmatter ${key} must be a YAML boolean, got "${fields.get(key)}"`)
  }
  return {
    name,
    description,
    modelInvocable: invocation['disable-model-invocation'] !== true,
    userInvocable: invocation['user-invocable'] !== false,
  }
}

function readManifest(targetRoot) {
  const path = join(targetRoot, MARKER)
  if (!existsSync(path)) return []
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8'))
    return Array.isArray(parsed?.skills) ? parsed.skills.filter(name => typeof name === 'string') : []
  } catch (error) {
    throw new Error(`deployed skill manifest is unreadable (${path}): ${error instanceof Error ? error.message : String(error)}`)
  }
}

function assertNotLinked(path) {
  const metadata = lstatSync(path)
  if (metadata.isSymbolicLink()) throw new Error(`refusing to deploy through a symlink: ${path}`)
  if (!metadata.isDirectory()) throw new Error(`skill target is not a directory: ${path}`)
}

/**
 * Copy every skill bundle from `sourceRoot` into `targetRoot`.
 *
 * @param options - source and target roots.
 * @returns the deployed skill names and their resolved invocation policy.
 */
export function deploySkills({ sourceRoot, targetRoot }) {
  const source = resolve(sourceRoot)
  const target = resolve(targetRoot)
  if (!existsSync(source)) throw new Error(`skill source root does not exist: ${source}`)
  mkdirSync(target, { recursive: true, mode: 0o755 })
  assertNotLinked(target)

  const deployed = []
  const discovered = []
  for (const entry of readdirSync(source, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const bundle = join(source, entry.name)
    if (!entry.isDirectory()) continue
    // A flat `<name>.md` is a valid DSH skill, but this distribution keeps shared
    // contract documents beside the skills, so only bundles are deployed.
    if (LEGACY_SKILLS.includes(entry.name)) continue
    const instruction = join(bundle, 'SKILL.md')
    if (!existsSync(instruction)) continue
    discovered.push({ name: entry.name, instruction })
  }

  for (const { name, instruction } of discovered) {
    const frontmatter = parseSkillFrontmatter(readFileSync(instruction, 'utf8'), `skills/${name}`)
    if (frontmatter.name !== name) {
      throw new Error(`skills/${name}: frontmatter name "${frontmatter.name}" must equal the directory name`)
    }
    const destination = join(target, name)
    if (existsSync(destination)) assertNotLinked(destination)
    mkdirSync(destination, { recursive: true, mode: 0o755 })
    for (const file of readdirSync(join(source, name), { withFileTypes: true })) {
      const from = join(source, name, file.name)
      const to = join(destination, file.name)
      if (file.isDirectory()) continue
      if (!file.isFile()) throw new Error(`skills/${name}: unsupported entry ${file.name}`)
      copyFileSync(from, to)
    }
    deployed.push(frontmatter)
  }

  const current = new Set(discovered.map(entry => entry.name))
  const removed = []
  for (const name of readManifest(target)) {
    if (current.has(name)) continue
    const stale = join(target, name)
    if (!existsSync(stale)) continue
    assertNotLinked(stale)
    rmSync(stale, { recursive: true, force: true })
    removed.push(name)
  }

  writeFileSync(
    join(target, MARKER),
    `${JSON.stringify({ version: 1, source, skills: deployed.map(skill => skill.name) }, undefined, 2)}\n`,
    { encoding: 'utf8', mode: 0o644 },
  )
  return { target, deployed, removed }
}

/** The DSH-scanned project skill root for one repository. */
export function dshSkillRoot(projectRoot) {
  return join(resolve(projectRoot), '.agents', 'skills')
}
