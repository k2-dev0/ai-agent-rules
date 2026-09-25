/**
 * The distribution's own skill provider.
 *
 * The bundle must not depend on a path that only exists in the developer's
 * checkout. Registering the provider here — rather than pointing the shipped
 * `dsh-skill-filesystem` at a `skills/` directory through YAML — makes the
 * distribution root a function of this bundle's own installed location, which
 * is what `import.meta.url` reports. The same code therefore works from a
 * checkout and from a profile's `node_modules`, and no absolute path is written
 * into any config.
 *
 * Only `<root>/<name>/SKILL.md` bundles are discovered, matching DSH's own
 * filesystem provider. The shared contract documents that sit beside the skills
 * in the distribution (`WORKFLOW_ROUTING.md` and friends) are deliberately not
 * skills and are therefore never published.
 */

import { existsSync, lstatSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { LEGACY_SKILLS } from './deploy-skills.js'

/** Frontmatter values DSH accepts as booleans. */
const TRUE_VALUES = new Set(['true', 'yes', 'on', '1'])
const FALSE_VALUES = new Set(['false', 'no', 'off', '0'])

const PROVIDER_NAME = 'distribution'

/**
 * The distribution's `skills/` directory.
 *
 * The bundle ships its own copy of the skills under `dsh/skills/`, so this
 * resolves inside the package directory both from a checkout and from a
 * profile's `node_modules`. A root outside the bundle is only a fallback: it
 * exists while developing but not after installation, so it is never the
 * intended source.
 */
export function distributionSkillsRoot(moduleUrl = import.meta.url) {
  const moduleDir = dirname(fileURLToPath(moduleUrl))
  const packageDir = resolve(moduleDir, '..')
  const candidates = [
    join(packageDir, 'skills'),
    join(packageDir, '..', 'skills'),
    join(packageDir, '..', '..', 'skills'),
  ]
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate
  }
  return candidates[0]
}

function parseScalar(raw) {
  const value = raw.trim()
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    return value.slice(1, -1)
  }
  return value === '' ? undefined : value
}

/**
 * Parse the frontmatter subset DSH reads.
 *
 * A malformed entry must drop the skill rather than silently permitting a
 * surface, which is what the strict boolean grammar below enforces.
 *
 * @returns the catalog fields, or `undefined` when the skill must be skipped.
 */
export function parseSkillFrontmatter(text) {
  const match = String(text).match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/)
  if (!match) return undefined
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
    if (currentKey === undefined) return undefined
  }
  const name = fields.get('name')
  const description = fields.get('description')
  if (typeof name !== 'string' || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name)) return undefined
  if (typeof description !== 'string' || description === '') return undefined

  const invocation = { modelInvocable: true, userInvocable: true }
  for (const [key, apply] of [
    ['disable-model-invocation', value => { invocation.modelInvocable = !value }],
    ['user-invocable', value => { invocation.userInvocable = value }],
  ]) {
    if (!fields.has(key)) continue
    const raw = String(fields.get(key)).toLowerCase()
    const bool = TRUE_VALUES.has(raw) ? true : FALSE_VALUES.has(raw) ? false : undefined
    if (bool === undefined) return undefined
    apply(bool)
  }
  return {
    name,
    description,
    whenToUse: typeof fields.get('whenToUse') === 'string' ? fields.get('whenToUse') : undefined,
    invocation,
  }
}

/** Strip the leading frontmatter block, leaving the instruction body. */
function stripFrontmatter(text) {
  return String(text).replace(/^---\r?\n[\s\S]*?\r?\n---(?:\r?\n|$)/, '')
}

/**
 * Discover the distribution's skill bundles.
 *
 * @param root - the distribution `skills/` directory.
 * @returns catalog candidates sorted by name.
 */
export function discoverDistributionSkills(root) {
  const candidates = []
  let entries
  try {
    entries = readdirSync(root, { withFileTypes: true })
  } catch {
    return candidates
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue
    // Legacy-only skills are part of the distribution but not of the DSH
    // catalog: they are Claude/Codex installation steps, so publishing them
    // would advertise a command that does nothing here.
    if (LEGACY_SKILLS.includes(entry.name)) continue
    const instructionPath = join(root, entry.name, 'SKILL.md')
    let text
    try {
      const metadata = lstatSync(instructionPath)
      if (!metadata.isFile() || metadata.isSymbolicLink()) continue
      text = readFileSync(instructionPath, 'utf8')
    } catch {
      continue
    }
    const parsed = parseSkillFrontmatter(text)
    if (parsed === undefined || parsed.name !== entry.name) continue
    candidates.push({
      path: instructionPath,
      name: parsed.name,
      description: parsed.description,
      ...(parsed.whenToUse === undefined ? {} : { whenToUse: parsed.whenToUse }),
      invocation: parsed.invocation,
      source: 'bundled',
      provider: PROVIDER_NAME,
      rank: 350,
      locator: { path: instructionPath },
      resourceBase: { kind: 'directory', path: join(root, entry.name) },
    })
  }
  return candidates.sort((left, right) => left.name.localeCompare(right.name))
}

/**
 * Register the distribution provider on the skill registry.
 *
 * @param ctx - the plugin context carrying `skills`.
 * @param options - optional root override, used by the unit tests.
 * @returns the disposer for this exact registration.
 */
export function registerDistributionSkills(ctx, options = {}) {
  const root = resolve(options.root ?? distributionSkillsRoot(options.moduleUrl))
  return ctx.skills.registerProvider(() => ({
    name: PROVIDER_NAME,
    list: async () => discoverDistributionSkills(root),
    get: async (candidate) => {
      const locator = candidate?.locator
      if (!locator || typeof locator.path !== 'string') return undefined
      let text
      try {
        text = readFileSync(locator.path, 'utf8')
      } catch {
        return undefined
      }
      const parsed = parseSkillFrontmatter(text)
      // A body whose name changed since discovery is stale; the registry drops
      // the selection rather than serving a mismatched definition.
      if (parsed === undefined || parsed.name !== candidate.name) return undefined
      return {
        path: locator.path,
        name: candidate.name,
        description: parsed.description,
        ...(parsed.whenToUse === undefined ? {} : { whenToUse: parsed.whenToUse }),
        invocation: parsed.invocation,
        source: 'bundled',
        provider: PROVIDER_NAME,
        content: stripFrontmatter(text),
        resourceBase: { kind: 'directory', path: dirname(locator.path) },
      }
    },
  }))
}

export { PROVIDER_NAME }
