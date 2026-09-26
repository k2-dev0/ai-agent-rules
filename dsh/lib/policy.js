import {
  createHash,
} from 'node:crypto'
import {
  existsSync,
  lstatSync,
  realpathSync,
  statSync,
} from 'node:fs'
import {
  basename,
  dirname,
  isAbsolute,
  join,
  normalize,
  parse,
  relative,
  resolve,
  sep,
} from 'node:path'
import { registeredCommandNames } from './routing-intent.js'

/**
 * Route table shared by the command registry and the tool guards.
 *
 * Every route needs a distinct `provider`/`model` pair, because
 * {@link routeFor} resolves an agent's role from exactly that pair. The coder
 * therefore uses its own model id (`glm-5.3-code`) declared over the same
 * upstream model as the planner's: reusing `glm-5.3` would make the coder's role
 * resolve to the planner's, and every coder guard would deny the work it exists
 * to allow. {@link assertRouteCommandConsistency} refuses a duplicate at
 * activation rather than letting that happen quietly.
 */
export const EXTERNAL_TOOLS = Object.freeze({
  external_research_design: Object.freeze({
    command: 'external-plan',
    provider: 'zai',
    model: 'glm-5.3',
    effort: 'max',
    // A design run reads a task's whole surface — the files it names and the
    // files those reference — before it can return its ordered handoff. At 4 a
    // recorded run was cancelled at step 5 while still reading, so the budget
    // only covered the investigation, never the answer.
    maxSteps: 8,
  }),
  external_opus_design: Object.freeze({
    command: 'opus-plan',
    provider: 'anthropic',
    model: 'claude-opus-5-5',
    effort: 'high',
    maxSteps: 8,
  }),
  external_code: Object.freeze({
    command: 'external-code',
    provider: 'zai',
    model: 'glm-5.3-code',
    effort: 'high',
    maxSteps: 6,
  }),
  review_change: Object.freeze({
    command: 'review',
    provider: 'openai',
    model: 'gpt-6-sol',
    effort: 'high',
    // A review reads a diff, follows up on what it found, and then answers. At 2
    // the child was cancelled while it was still assembling its verdict, and the
    // caller saw only `subagent run was cancelled`.
    maxSteps: 6,
  }),
})

/**
 * The compat fields one wire protocol requires a route's model entry to declare.
 *
 * A route names a model id the installed pi-ai catalog may not ship — it ships
 * neither `claude-opus-5-5` (0.85.1 stops at `claude-opus-5`) nor the zai ids —
 * and for those ids the model entry is the only description that exists. The
 * requirement is stated per protocol because that is where the shape is decided:
 * `anthropic-messages` sends budget-based thinking unless the model carries
 * `forceAdaptiveThinking`, and an adaptive-only model rejects that request
 * before producing any output (zero token usage, so the failure names neither
 * the route nor the field). The OpenAI-style protocols infer their request shape
 * from the endpoint, so an id they do not describe still works and needs nothing
 * declared here.
 */
export const ROUTE_MODEL_REQUIREMENTS = Object.freeze({
  'anthropic-messages': Object.freeze(['forceAdaptiveThinking']),
})

export const DESIGN_HANDOFF_HEADINGS = Object.freeze([
  '# Design Handoff',
  '## 目的',
  '## 調査した範囲と根拠',
  '## 機能要件',
  '## 非機能要件',
  '## 制約・前提',
  '## 対象外',
  '## 現行構造',
  '## 採用する概要設計',
  '## コンポーネント境界',
  '## データフロー',
  '## インターフェース',
  '## 保存・状態遷移',
  '## 障害・再試行・ロールバック',
  '## 採用しなかった案',
  '## 詳細設計で守る制約',
  '## 受入条件',
  '## 未解決事項',
])

/**
 * Directory names whose presence makes every path below them protected.
 *
 * `skills` is here because a skill body is an instruction source: the catalog
 * grants capabilities from it, and the Codex/Claude flows read the same files as
 * their routing contract. A model that can rewrite a skill can grant itself what
 * the skill authorizes, so the legacy `deny-skill-source.sh` rule is enforced
 * here by path rather than left to the skill's own prose.
 */
const PROTECTED_COMPONENTS = new Set([
  '.git',
  '.agents',
  '.dsh',
  '.codex',
  '.claude',
  'hooks',
  'skills',
])

const PROTECTED_BASENAMES = new Set([
  'AGENTS.md',
  'AGENTS.local.md',
  'AGENTS.override.md',
  'CLAUDE.md',
  'CLAUDE.local.md',
  'cordis.yml',
  'cordis.patch.yml',
  'settings.yaml',
  '.credentials.yaml',
  'package-lock.json',
  'pnpm-lock.yaml',
  'yarn.lock',
  'bun.lock',
  'bun.lockb',
  'uv.lock',
  'Cargo.lock',
  'poetry.lock',
  'composer.lock',
  'Gemfile.lock',
])

const MUTATING_SHELL = /(?:^|[;&|\s])(rm|rmdir|unlink|shred|srm|mv|cp|rsync|install|dd|truncate|tee|ln|mkdir|touch|chmod|chown|chgrp|sed\s+[^;&|]*-i)(?:\s|$)/i
const PROTECTED_SHELL_TOKEN = /(?:^|[\s"'=/])(?:\.git|\.agents|\.dsh|\.codex|\.claude|hooks|skills|AGENTS(?:\.local|\.override)?\.md|CLAUDE(?:\.local)?\.md|cordis(?:\.patch)?\.yml|settings\.yaml|\.credentials\.yaml|\.env(?:\.[^\s"']+)?|(?:package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|uv\.lock|Cargo\.lock|poetry\.lock|composer\.lock|Gemfile\.lock)|[^\s"']*review-state[^\s"']*)(?:[\s"'/]|$)/i
const SHELL_CONTROL = /[\n\r;&|<>`]|\$\(/
/*
 * The literal allowlisted npm/pnpm/yarn/bun script names. Kept as an explicit
 * list rather than a pattern so widening it is always a deliberate, reviewable
 * edit: an unknown script name still needs a sandbox escalation.
 */
const ALLOWED_PACKAGE_SCRIPTS = Object.freeze([
  'test',
  'lint',
  'typecheck',
  'check',
  'build',
  'verify',
])

/*
 * A script name must be followed by whitespace or end-of-input. The explicit
 * negative lookahead keeps the regex engine from backtracking a rejected script
 * name into `??\s+test`; with it, only a script whose literal name is `test`
 * matches the bare-`test` alternative.
 */
const PACKAGE_YARD = '(?:npm|pnpm|yarn|bun)'
const SCRIPT_END = '(?!\\S)'
// Only `verify` accepts a `:<qualifier>` suffix (`verify:e2e`), and the
// qualifier grammar is restricted to lowercase kebab-case.
const ALLOWED_SCRIPT_PATTERN = ALLOWED_PACKAGE_SCRIPTS
  .map(name => (name === 'verify' ? 'verify(?::[a-z0-9]+(?:-[a-z0-9]+)*)?' : name))
  .join('|')

const SAFE_MAIN_COMMAND = new RegExp(
  '^(?:pwd|ls(?:\\s|$)|find(?:\\s|$)|rg(?:\\s|$)|grep(?:\\s|$)|head(?:\\s|$)|tail(?:\\s|$)|wc(?:\\s|$)'
  + '|sed\\s+-n(?:\\s|$)'
  + '|git\\s+(?:status|diff|show|log|rev-parse|ls-files|branch\\s+--show-current)(?:\\s|$)'
  + `|${PACKAGE_YARD}\\s+run\\s+(?:${ALLOWED_SCRIPT_PATTERN})${SCRIPT_END}`
  + `|${PACKAGE_YARD}\\s+test${SCRIPT_END}`
  + '|pytest(?:\\s|$)|python3?\\s+-m\\s+pytest(?:\\s|$)'
  + '|cargo\\s+(?:test|check|clippy)(?:\\s|$)|go\\s+test(?:\\s|$)'
  + '|make\\s+(?:test|check|lint|build)(?:\\s|$))',
)
const EXTERNAL_CODE_COMMAND = /^(?:(?:npm|pnpm|yarn|bun)\s+(?:test|run\s+(?:test|lint|typecheck|check|build|format))(?:\s|$)|pytest(?:\s|$)|python3?\s+-m\s+pytest(?:\s|$)|cargo\s+(?:test|check|clippy|fmt\s+--check)(?:\s|$)|go\s+test(?:\s|$)|gofmt\s+-d(?:\s|$)|make\s+(?:test|check|lint|build|format-check)(?:\s|$))/
const READ_ONLY_GIT = new Set([
  'status',
  'diff',
  'show',
  'log',
  'rev-parse',
  'ls-files',
  'branch',
  'cat-file',
  'merge-base',
  'name-rev',
])

function contentText(content) {
  if (!Array.isArray(content)) return ''
  return content
    .filter(block => block && block.type === 'text' && typeof block.text === 'string')
    .map(block => block.text)
    .join('\n')
}

/**
 * Names of the routing commands that appear as a bare token in direct user text.
 *
 * This is deliberately not a keyword or natural-language classifier: it reports
 * only an exact, whitespace-bounded slash-command token. Routing itself is
 * driven by {@link RoutingIntentStore}; this helper exists so other surfaces can
 * recognize the same token spelling without inventing a second grammar.
 */
export function commandTokens(text) {
  const source = String(text ?? '')
  return registeredCommandNames().filter(name => new RegExp(`(?:^|\\s)/${name}(?:\\s|$)`).test(source))
}

export function latestDirectUserMessage(session) {
  const events = session?.snapshotEvents?.() ?? []
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event.type === 'turn/start') break
    if (event.type !== 'user/message') continue
    if (event.data?.source?.kind !== 'user') continue
    const text = contentText(event.data.content)
    return { id: String(event.data.id), text, commands: commandTokens(text) }
  }
  return undefined
}

/**
 * The turn currently open in a session log, or `undefined` between turns.
 *
 * An intent is bound to this number so a routing decision can never be reused
 * by a later turn even if the same user text is replayed.
 */
export function currentTurn(session) {
  const events = session?.snapshotEvents?.() ?? []
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event.type === 'turn/end') return undefined
    if (event.type === 'turn/start') {
      const turn = event.data?.turn
      return Number.isInteger(turn) ? turn : undefined
    }
  }
  return undefined
}

function canonicalizeExisting(path) {
  let cursor = path
  const missing = []
  while (!existsSync(cursor)) {
    const parent = dirname(cursor)
    if (parent === cursor) return normalize(path)
    missing.unshift(basename(cursor))
    cursor = parent
  }
  return join(realpathSync.native(cursor), ...missing)
}

export function canonicalTarget(inputPath, cwd) {
  const displayPath = isAbsolute(inputPath) ? inputPath : resolve(cwd, inputPath)
  return canonicalizeExisting(normalize(displayPath))
}

function pathParts(path) {
  return normalize(path).split(sep).filter(Boolean)
}

function sameOrInside(parent, child) {
  const rel = relative(parent, child)
  return rel === '' || (!rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel))
}

export function protectedPathReason(inputPath, cwd, extraProtected = []) {
  if (typeof inputPath !== 'string' || inputPath.length === 0) return 'empty path'
  let canonical
  try {
    canonical = canonicalTarget(inputPath, cwd)
  } catch (error) {
    return `path resolution failed: ${error instanceof Error ? error.message : String(error)}`
  }
  const lowerParts = pathParts(canonical).map(part => part.toLowerCase())
  for (const component of PROTECTED_COMPONENTS) {
    if (lowerParts.includes(component.toLowerCase())) return `protected component ${component}`
  }
  const name = basename(canonical)
  if (PROTECTED_BASENAMES.has(name)) return `protected file ${name}`
  if (/^\.env(?:\..+)?$/i.test(name)) return 'protected environment file'
  if (/review-state/i.test(name) || lowerParts.includes('.review')) return 'protected review state'
  for (const protectedPath of extraProtected) {
    const fixed = canonicalTarget(protectedPath, cwd)
    if (sameOrInside(fixed, canonical) || sameOrInside(canonical, fixed)) return `protected runtime state ${fixed}`
  }
  if (existsSync(canonical)) {
    try {
      const metadata = lstatSync(canonical)
      if (metadata.isSymbolicLink()) return 'symbolic-link mutation is denied'
      const targetMetadata = statSync(canonical)
      if (targetMetadata.isFile() && targetMetadata.nlink > 1) return 'hard-linked file mutation is denied'
    } catch (error) {
      return `metadata inspection failed: ${error instanceof Error ? error.message : String(error)}`
    }
  }
  return undefined
}

export function shellProtectedMutationReason(command) {
  if (typeof command !== 'string' || command.trim() === '') return 'empty command'
  if (!PROTECTED_SHELL_TOKEN.test(command)) return undefined
  if (MUTATING_SHELL.test(command) || /(?:^|[^<])>>?/.test(command) || /--delete(?:\s|=|$)/.test(command)) {
    return 'shell command can mutate a protected path'
  }
  return undefined
}

export function needsRawShellApproval(command) {
  if (typeof command !== 'string' || command.trim() === '') return true
  if (SHELL_CONTROL.test(command)) return true
  return !SAFE_MAIN_COMMAND.test(command.trim())
}

export function isExternalCodeCommand(command) {
  const source = String(command ?? '').trim()
  return source.length > 0 && !SHELL_CONTROL.test(source) && EXTERNAL_CODE_COMMAND.test(source)
}

export function splitSimpleCommand(command) {
  if (SHELL_CONTROL.test(command)) return undefined
  const tokens = []
  let current = ''
  let quote = ''
  let escaped = false
  for (const character of command.trim()) {
    if (escaped) {
      current += character
      escaped = false
      continue
    }
    if (character === '\\' && quote !== "'") {
      escaped = true
      continue
    }
    if (quote) {
      if (character === quote) quote = ''
      else current += character
      continue
    }
    if (character === "'" || character === '"') {
      quote = character
      continue
    }
    if (/\s/.test(character)) {
      if (current) tokens.push(current)
      current = ''
      continue
    }
    current += character
  }
  if (escaped || quote) return undefined
  if (current) tokens.push(current)
  return tokens
}

export function gitCommandPolicy(command) {
  const tokens = splitSimpleCommand(command)
  if (!tokens || tokens[0] !== 'git' || !tokens[1]) return { kind: 'not-git' }
  const subcommand = tokens[1]
  if (READ_ONLY_GIT.has(subcommand)) return { kind: 'read' }
  if (subcommand === 'add') {
    const separator = tokens.indexOf('--', 2)
    const paths = separator === -1
      ? tokens.slice(2).filter(token => !token.startsWith('-'))
      : tokens.slice(separator + 1)
    if (paths.length !== 1) return { kind: 'deny', reason: 'git add must stage exactly one explicit path' }
    return { kind: 'add', path: paths[0] }
  }
  if (subcommand === 'commit') {
    if (!tokens.includes('-m') && !tokens.includes('--message')) {
      return { kind: 'deny', reason: 'git commit requires a non-interactive message' }
    }
    return { kind: 'commit' }
  }
  if (subcommand === 'restore' && tokens.includes('--staged')) return { kind: 'restore-staged' }
  return { kind: 'deny', reason: `git ${subcommand} is not allowed` }
}

function extractTaggedJson(prompt, tag) {
  const match = String(prompt ?? '').match(new RegExp(`<${tag}>\\s*([\\s\\S]*?)\\s*</${tag}>`))
  if (!match) throw new Error(`missing <${tag}> JSON block`)
  let value
  try {
    value = JSON.parse(match[1])
  } catch (error) {
    throw new Error(`invalid <${tag}> JSON: ${error instanceof Error ? error.message : String(error)}`)
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`<${tag}> must contain one JSON object`)
  return value
}

function relativeTaskPath(value, label) {
  if (typeof value !== 'string' || value.length === 0 || isAbsolute(value)) throw new Error(`${label} must be a non-empty relative path`)
  const fixed = normalize(value)
  if (fixed === '..' || fixed.startsWith(`..${sep}`)) throw new Error(`${label} escapes the workspace`)
  return fixed
}

export function parseImplementationHandoff(prompt) {
  const value = extractTaggedJson(prompt, 'implementation_handoff')
  if (typeof value.objective !== 'string' || value.objective.trim() === '') throw new Error('implementation_handoff.objective is required')
  if (!Array.isArray(value.allowedPaths) || value.allowedPaths.length === 0) throw new Error('implementation_handoff.allowedPaths must be non-empty')
  if (!Array.isArray(value.forbiddenPaths)) throw new Error('implementation_handoff.forbiddenPaths must be an array')
  if (!Array.isArray(value.allowedCommands)) throw new Error('implementation_handoff.allowedCommands must be an array')
  if (!Array.isArray(value.requiredTests) || value.requiredTests.length === 0) throw new Error('implementation_handoff.requiredTests must be non-empty')
  const allowedPaths = value.allowedPaths.map((path, index) => relativeTaskPath(path, `allowedPaths[${index}]`))
  const forbiddenPaths = value.forbiddenPaths.map((path, index) => relativeTaskPath(path, `forbiddenPaths[${index}]`))
  const allowedCommands = value.allowedCommands.map((command, index) => {
    if (typeof command !== 'string' || !isExternalCodeCommand(command)) {
      throw new Error(`allowedCommands[${index}] must be one allowlisted test/lint/typecheck/build/format command`)
    }
    return command.trim()
  })
  const requiredTests = value.requiredTests.map((test, index) => {
    if (typeof test !== 'string' || test.trim() === '') throw new Error(`requiredTests[${index}] must be non-empty`)
    return test.trim()
  })
  return { objective: value.objective.trim(), allowedPaths, forbiddenPaths, allowedCommands, requiredTests }
}

export function parseReviewInput(prompt) {
  const value = extractTaggedJson(prompt, 'review_input')
  for (const key of ['base', 'head']) {
    if (typeof value[key] !== 'string' || !/^[0-9a-f]{40}$/i.test(value[key])) throw new Error(`review_input.${key} must be a full 40-hex SHA`)
  }
  if (value.base.toLowerCase() === value.head.toLowerCase()) throw new Error('review_input base and head must differ')
  if (typeof value.requirementsHash !== 'string' || !/^sha256:[0-9a-f]{64}$/i.test(value.requirementsHash)) {
    throw new Error('review_input.requirementsHash must be sha256:<64-hex>')
  }
  if (typeof value.requirements !== 'string' || value.requirements.trim() === '') {
    throw new Error('review_input.requirements must be a non-empty string')
  }
  const actualHash = `sha256:${createHash('sha256').update(value.requirements, 'utf8').digest('hex')}`
  if (actualHash !== value.requirementsHash.toLowerCase()) throw new Error('review_input.requirementsHash does not match requirements')
  return {
    base: value.base.toLowerCase(),
    head: value.head.toLowerCase(),
    requirementsHash: value.requirementsHash.toLowerCase(),
    requirements: value.requirements,
  }
}

export function validateDesignHandoff(text) {
  let position = -1
  for (const heading of DESIGN_HANDOFF_HEADINGS) {
    const next = String(text ?? '').indexOf(heading, position + 1)
    if (next === -1) return { valid: false, reason: `missing or out-of-order heading: ${heading}` }
    position = next
  }
  return { valid: true }
}

function stripJsonFence(text) {
  const trimmed = String(text ?? '').trim()
  const match = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i)
  return match ? match[1] : trimmed
}

export function validateReviewOutput(text, input) {
  let value
  try {
    value = JSON.parse(stripJsonFence(text))
  } catch (error) {
    return { valid: false, reason: `review output is not JSON: ${error instanceof Error ? error.message : String(error)}` }
  }
  if (!value || typeof value !== 'object' || Array.isArray(value)) return { valid: false, reason: 'review output must be one JSON object' }
  if (value.status !== 'complete' && value.status !== 'incomplete') return { valid: false, reason: 'review status must be complete or incomplete' }
  if (String(value.base).toLowerCase() !== input.base || String(value.head).toLowerCase() !== input.head) return { valid: false, reason: 'review SHA does not match input' }
  if (String(value.requirementsHash).toLowerCase() !== input.requirementsHash) return { valid: false, reason: 'review requirements hash does not match input' }
  if (!Array.isArray(value.findings)) return { valid: false, reason: 'review findings must be an array' }
  if (value.status === 'incomplete' && typeof value.unchecked !== 'string') return { valid: false, reason: 'incomplete review must name unchecked scope' }
  return { valid: true, value }
}

/**
 * The role an agent's fixed provider/model pair identifies.
 *
 * Two routes must never share a pair. The lookup returns the first match, so a
 * duplicate would silently make the later route unreachable: its role would
 * resolve to the earlier one's, and every guard written for it would deny the
 * work it exists to do. {@link assertRouteCommandConsistency} refuses a
 * duplicate at activation for exactly that reason.
 */
export function routeFor(provider, model) {
  return Object.entries(EXTERNAL_TOOLS).find(([, value]) => value.provider === provider && value.model === model)?.[0]
    ?? (provider === 'deepseek-official' && model === 'deepseek-flash' ? 'main' : undefined)
}

/**
 * Every route tool must have exactly one registered command, and vice versa.
 *
 * The route table and the command registry are separate declarations on purpose
 * (one drives tool guards, the other the command registry), so this check keeps
 * a drift between them from silently disabling or duplicating a route.
 *
 * It also refuses two routes that share a provider/model pair. Role resolution
 * reads that pair, so a duplicate makes one route's role unreachable and turns
 * its guards into blanket denials — a defect that looks like enforcement.
 *
 * It runs at plugin activation, where any of these fails the profile.
 */
export function assertRouteCommandConsistency() {
  const commands = registeredCommandNames()
  const tools = Object.keys(EXTERNAL_TOOLS)
  const missingTool = commands.filter(command => !tools.some(tool => EXTERNAL_TOOLS[tool].command === command))
  if (missingTool.length > 0) {
    throw new Error(`routing command(s) without a route tool: ${missingTool.join(', ')}`)
  }
  const missingCommand = tools.filter(tool => !commands.includes(EXTERNAL_TOOLS[tool].command))
  if (missingCommand.length > 0) {
    throw new Error(`route tool(s) without a registered command: ${missingCommand.join(', ')}`)
  }
  const byPair = new Map()
  for (const [tool, route] of Object.entries(EXTERNAL_TOOLS)) {
    const pair = `${route.provider}/${route.model}`
    const seen = byPair.get(pair)
    if (seen !== undefined) {
      throw new Error(
        `route tools ${seen} and ${tool} share the provider/model pair ${pair}; `
        + 'role resolution reads that pair, so one of the two roles would be unreachable',
      )
    }
    byPair.set(pair, tool)
  }
  return true
}

/**
 * The provider routes a patch declares, each with its api and the compat of
 * every model entry.
 *
 * The bundle writes `cordis.patch.yml` itself, so its shape is a contract rather
 * than a guess: providers sit at six spaces under `providers:`, a route's `api`
 * and `models:` at eight, each model entry at ten, and its fields at twelve.
 * Reading that indentation is what keeps a `model:` or a `compat:` belonging to
 * another row from being attributed to this one — a substring search would take
 * the first match in the file, which is the zai block that precedes anthropic.
 *
 * @param patchText - the contents of `cordis.patch.yml`.
 * @returns providers by id, each with its route api and its models by id.
 */
function declaredProviders(patchText) {
  const providers = new Map()
  let provider
  let model
  let block
  for (const raw of String(patchText).split(/\r?\n/)) {
    const line = raw.trimEnd()
    const content = line.trim()
    if (content === '' || content.startsWith('#')) continue
    const indent = line.length - line.trimStart().length
    if (indent <= 4) {
      provider = undefined
      model = undefined
      block = undefined
      continue
    }
    if (indent === 6) {
      const key = content.match(/^([A-Za-z0-9._-]+):$/)
      provider = key ? { api: undefined, models: new Map() } : undefined
      if (provider) providers.set(key[1], provider)
      model = undefined
      block = undefined
      continue
    }
    if (provider === undefined) continue
    if (indent === 8) {
      const api = content.match(/^api:\s*(\S+)$/)
      if (api) provider.api = api[1]
      model = undefined
      block = undefined
      continue
    }
    if (indent === 10) {
      const id = content.match(/^-\s*id:\s*(\S+)$/)
      model = id ? { api: undefined, compat: new Set() } : undefined
      if (model) provider.models.set(id[1], model)
      block = undefined
      continue
    }
    if (model === undefined) continue
    if (indent === 12) {
      block = content.match(/^([A-Za-z0-9_]+):$/)?.[1]
      const api = content.match(/^api:\s*(\S+)$/)
      if (api) model.api = api[1]
      continue
    }
    if (block === 'compat') model.compat.add(content.split(':', 1)[0])
  }
  return providers
}

/**
 * Every route's declared model must carry the compat its protocol requires.
 *
 * This runs at activation against the bundle's own patch, so a declaration that
 * would only fail on the first request fails the profile instead. The message
 * names the route, its protocol, and the missing field, because the alternative
 * is a provider rejection with zero token usage that names none of them.
 *
 * @param patchText - the contents of the bundle's own `cordis.patch.yml`.
 * @param routes - the route table to verify; defaults to every route.
 * @returns true when every route is described well enough to serve a request.
 * @throws when a route, its model entry, its protocol, or a required compat
 *   field is missing.
 */
export function assertRouteDeclarations(patchText, routes = EXTERNAL_TOOLS) {
  const providers = declaredProviders(patchText)
  const problems = []
  for (const [tool, route] of Object.entries(routes)) {
    const provider = providers.get(route.provider)
    if (provider === undefined) {
      problems.push(`${tool}: the patch declares no provider route "${route.provider}"`)
      continue
    }
    const model = provider.models.get(route.model)
    if (model === undefined) {
      problems.push(`${tool}: provider "${route.provider}" declares no model entry "${route.model}"`)
      continue
    }
    const api = model.api ?? provider.api
    if (api === undefined) {
      problems.push(`${tool}: neither route "${route.provider}" nor model "${route.model}" names its api,`
        + ' so only an installed pi-ai catalog entry can describe it; declare the api in cordis.patch.yml')
      continue
    }
    for (const field of ROUTE_MODEL_REQUIREMENTS[api] ?? []) {
      if (model.compat.has(field)) continue
      problems.push(`${tool} (${route.provider}/${route.model}) speaks ${api}, which needs`
        + ` compat.${field}: true on the model entry: without it pi-ai sends budget-based thinking,`
        + ' which a model the installed catalog does not describe rejects before producing any output,'
        + ' and the caller sees only `subagent run failed`. Declare the field in cordis.patch.yml,'
        + ' or name a model the installed catalog ships.')
    }
  }
  if (problems.length > 0) {
    throw new Error(`route declaration check failed:\n- ${problems.join('\n- ')}`)
  }
  return true
}

export function isInsideAllowedPath(target, cwd, allowedPaths, forbiddenPaths = []) {
  const canonical = canonicalTarget(target, cwd)
  const allowed = allowedPaths.some(path => sameOrInside(canonicalTarget(path, cwd), canonical))
  const forbidden = forbiddenPaths.some(path => sameOrInside(canonicalTarget(path, cwd), canonical))
  return allowed && !forbidden
}

export function commandMatchesAllowlist(command, allowedCommands) {
  return allowedCommands.includes(String(command ?? '').trim())
}

/**
 * Whether the reviewer may run one shell command.
 *
 * A reviewer sees only the frozen review range. Every accepted command is a
 * Git read: `status` and `ls-files` are inherently range-free reads that cannot
 * change the worktree, the index, or the object database; every other accepted
 * read must name the supplied base or head so the reviewer can never inspect an
 * unpinned revision.
 */
export function reviewGitCommandAllowed(command, input) {
  const tokens = splitSimpleCommand(command)
  if (!tokens || tokens[0] !== 'git' || !READ_ONLY_GIT.has(tokens[1])) return false
  const rest = tokens.slice(2)
  // Nothing that writes to the worktree, the index, or the object database.
  if (rest.some(token => /^(?:-[a-zA-Z]*[wWaAdDfF]|--(?:force|hard|mixed|soft|merge|keep|delete|prune|update-ref))/.test(token))) {
    return false
  }
  if (tokens[1] === 'status' || tokens[1] === 'ls-files') return true
  const joined = rest.join(' ')
  return joined.includes(input.base) || joined.includes(input.head)
}

export function outputText(value) {
  if (!value || value.kind !== 'foreground' || !Array.isArray(value.output)) return ''
  return value.output
    .filter(block => block && block.type === 'text' && typeof block.text === 'string')
    .map(block => block.text)
    .join('')
}

/**
 * Add a policy cancellation reason to the failure a route tool reported.
 *
 * A child the policy cancelled reaches the caller as the tool's own fixed
 * wording (`subagent run was cancelled`), and the reason it was cancelled — a
 * step budget, in practice — is what makes that actionable. The reason is
 * appended rather than substituted: the tool's own failure stays the headline,
 * and a policy note must not relabel a provider error as a policy verdict.
 *
 * @param result - the route tool's result.
 * @param reason - the recorded policy reason, when one exists for this run.
 * @returns the result, annotated only when a reason applies.
 */
export function annotateCancelledRun(result, reason) {
  if (typeof reason !== 'string' || reason === '') return result
  if (!result || result.isError !== true) return result
  const note = `\nDSH policy: ${reason}`
  const content = Array.isArray(result.content) && result.content.length > 0
    ? result.content.map((block, index) => (index === result.content.length - 1
      && block?.type === 'text' && typeof block.text === 'string'
      ? { ...block, text: `${block.text}${note}` }
      : block))
    : [{ type: 'text', text: `Error:${note}` }]
  const message = typeof result.error?.message === 'string' && result.error.message !== ''
    ? `${result.error.message}${note}`
    : `route run cancelled${note}`
  return { ...result, error: { ...result.error, message }, content }
}

export function resolveWorkspacePath(cwd, input) {
  const root = canonicalTarget(cwd, cwd)
  const target = canonicalTarget(input, cwd)
  return sameOrInside(root, target) ? target : undefined
}

export function defaultStatePaths(config, cwd) {
  const root = config?.stateRoot ? resolve(config.stateRoot) : resolve(cwd, '.dsh')
  return {
    root,
    mutationLock: config?.mutationLockPath ? resolve(config.mutationLockPath) : join(root, 'mutation-lock.json'),
  }
}

export function filesystemRoot(path) {
  return parse(resolve(path)).root
}
