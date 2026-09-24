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

export const EXTERNAL_TOOLS = Object.freeze({
  external_research_design: Object.freeze({
    flag: 'externalPlan',
    provider: 'zai',
    model: 'glm-5.3',
    effort: 'max',
    maxSteps: 4,
    warningUsd: 3,
  }),
  external_opus_design: Object.freeze({
    flag: 'opusPlan',
    provider: 'anthropic',
    model: 'claude-opus-5-5',
    effort: 'high',
    maxSteps: 4,
    warningUsd: 6,
  }),
  external_code: Object.freeze({
    flag: 'externalCode',
    provider: 'zai',
    model: 'glm-5.3',
    effort: 'high',
    maxSteps: 6,
    warningUsd: 4,
  }),
  review_change: Object.freeze({
    flag: 'review',
    provider: 'openai',
    model: 'gpt-6-sol',
    effort: 'high',
    maxSteps: 2,
    warningUsd: 1,
  }),
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

export const DEFAULT_PRICES = Object.freeze({
  // Peak DeepSeek rates. Off-peak savings deliberately do not weaken the cap.
  'deepseek-official/deepseek-flash': Object.freeze({
    input: 0.30,
    cacheRead: 0.006,
    cacheWrite: 0.30,
    output: 1.20,
  }),
  'zai/glm-5.3': Object.freeze({
    input: 1.40,
    cacheRead: 0.26,
    cacheWrite: 1.40,
    output: 4.40,
  }),
  // One-hour cache writes are the conservative Anthropic cache-write rate.
  'anthropic/claude-opus-5-5': Object.freeze({
    input: 4.00,
    cacheRead: 0.20,
    cacheWrite: 8.00,
    output: 20.00,
  }),
  // Long-context standard rates plus the 10% regional-processing premium.
  'openai/gpt-6-sol': Object.freeze({
    input: 4.40,
    cacheRead: 0.44,
    cacheWrite: 5.50,
    output: 16.50,
  }),
})

export const BUDGET_THRESHOLDS = Object.freeze({
  notify: 100,
  estimate: 120,
  confirm: 140,
  normalStop: 150,
  externalStop: 180,
  deepseekLongStop: 195,
  absoluteStop: 200,
})

const PROTECTED_COMPONENTS = new Set([
  '.git',
  '.agents',
  '.dsh',
  '.codex',
  '.claude',
  'hooks',
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
const PROTECTED_SHELL_TOKEN = /(?:^|[\s"'=/])(?:\.git|\.agents|\.dsh|\.codex|\.claude|hooks|AGENTS(?:\.local|\.override)?\.md|CLAUDE(?:\.local)?\.md|cordis(?:\.patch)?\.yml|settings\.yaml|\.credentials\.yaml|\.env(?:\.[^\s"']+)?|(?:package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?|uv\.lock|Cargo\.lock|poetry\.lock|composer\.lock|Gemfile\.lock)|[^\s"']*review-state[^\s"']*)(?:[\s"'/]|$)/i
const SHELL_CONTROL = /[\n\r;&|<>`]|\$\(/
const SAFE_MAIN_COMMAND = /^(?:pwd|ls(?:\s|$)|find(?:\s|$)|rg(?:\s|$)|grep(?:\s|$)|head(?:\s|$)|tail(?:\s|$)|wc(?:\s|$)|sed\s+-n(?:\s|$)|git\s+(?:status|diff|show|log|rev-parse|ls-files|branch\s+--show-current)(?:\s|$)|(?:npm|pnpm|yarn|bun)\s+(?:test|run\s+(?:test|lint|typecheck|check|build))(?:\s|$)|pytest(?:\s|$)|python3?\s+-m\s+pytest(?:\s|$)|cargo\s+(?:test|check|clippy)(?:\s|$)|go\s+test(?:\s|$)|make\s+(?:test|check|lint|build)(?:\s|$))/
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

function positiveLine(text, pattern) {
  return text.split(/\r?\n/).some(line => pattern.test(line)
    && !/(?:使わない|不要|禁止|しない|do\s+not|don't|without|disable)/i.test(line))
}

export function routingFlags(text) {
  const source = String(text ?? '')
  const externalPlan = /(?:^|\s)\/external-plan(?:\s|$)/.test(source)
    || positiveLine(source, /(?:GLM(?:-5\.3)?)(?:で|を使って|による).*(?:調査|要件整理|概要設計)/i)
    || positiveLine(source, /(?:use|ask)\s+GLM(?:-5\.3)?.*(?:research|requirements|high-level design|architecture)/i)
  const opusPlan = /(?:^|\s)\/opus-plan(?:\s|$)/.test(source)
    || positiveLine(source, /(?:Claude\s+)?Opus(?:\s*5\.5)?(?:で|を使って|による).*(?:調査|要件整理|概要設計)/i)
    || positiveLine(source, /(?:use|ask)\s+(?:Claude\s+)?Opus(?:\s*5\.5)?.*(?:research|requirements|high-level design|architecture)/i)
  const externalCode = /(?:^|\s)\/external-code(?:\s|$)/.test(source)
    || positiveLine(source, /(?:GLM(?:-5\.3)?)(?:で|を使って|による).*(?:実装|修正|コーディング)/i)
    || positiveLine(source, /(?:use|ask)\s+GLM(?:-5\.3)?.*(?:implement|code|coding)/i)
  const review = /(?:^|\s)\/review(?:\s|$)/.test(source)
    || positiveLine(source, /(?:GPT-?6\s*Sol)(?:で|を使って|による).*(?:レビュー|監査)/i)
    || positiveLine(source, /(?:review|audit).*(?:with|using)\s+GPT-?6\s*Sol/i)
  return {
    externalPlan,
    opusPlan,
    externalCode,
    review,
    approveBudget: /(?:^|\s)\/approve-budget(?:\s|$)/.test(source),
    conflict: externalPlan && opusPlan,
  }
}

export function latestDirectUserMessage(session) {
  const events = session?.snapshotEvents?.() ?? []
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event.type === 'turn/start') break
    if (event.type !== 'user/message') continue
    if (event.data?.source?.kind !== 'user') continue
    return {
      id: String(event.data.id),
      text: contentText(event.data.content),
      flags: routingFlags(contentText(event.data.content)),
    }
  }
  return undefined
}

export function routingDecision(toolName, session, alreadyUsed = false) {
  const route = EXTERNAL_TOOLS[toolName]
  if (!route) return { allowed: true }
  if ((session?.header?.delegationDepth ?? 0) !== 0) {
    return { allowed: false, reason: '外部agentから別の外部agentを起動できません。' }
  }
  const direct = latestDirectUserMessage(session)
  if (!direct) return { allowed: false, reason: '現在turnのdirect user messageがないため外部modelを起動できません。' }
  if (direct.flags.conflict) {
    return { allowed: false, reason: '`/external-plan`と`/opus-plan`は同一taskで併用できません。' }
  }
  if (!direct.flags[route.flag]) {
    return { allowed: false, reason: `${toolName}は現在turnのdirect user messageに対応する明示指定がある場合だけ実行できます。` }
  }
  if (alreadyUsed) {
    return { allowed: false, reason: `${toolName}は1つのdirect user messageに対して1回だけ実行できます。` }
  }
  return { allowed: true, direct }
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

export function routeFor(provider, model) {
  return Object.entries(EXTERNAL_TOOLS).find(([, value]) => value.provider === provider && value.model === model)?.[0]
    ?? (provider === 'deepseek-official' && model === 'deepseek-flash' ? 'main' : undefined)
}

export function calculateCost(usage, provider, model, prices = DEFAULT_PRICES) {
  const price = prices[`${provider}/${model}`]
  if (!price) throw new Error(`missing price for ${provider}/${model}`)
  const count = (name) => {
    const value = usage?.[name] ?? 0
    if (!Number.isFinite(value) || value < 0) throw new Error(`invalid usage.${name}`)
    return value
  }
  return (
    count('inputTokens') * price.input
    + count('cacheReadTokens') * price.cacheRead
    + count('cacheWriteTokens') * price.cacheWrite
    + count('outputTokens') * price.output
  ) / 1_000_000
}

export function utcMonth(timestamp = Date.now()) {
  return new Date(timestamp).toISOString().slice(0, 7)
}

export function budgetTier(total, thresholds = BUDGET_THRESHOLDS) {
  if (total >= thresholds.absoluteStop) return 'absolute-stop'
  if (total >= thresholds.deepseekLongStop) return 'deepseek-long-stop'
  if (total >= thresholds.externalStop) return 'external-stop'
  if (total >= thresholds.normalStop) return 'normal-stop'
  if (total >= thresholds.confirm) return 'confirm'
  if (total >= thresholds.estimate) return 'estimate'
  if (total >= thresholds.notify) return 'notify'
  return 'normal'
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

export function reviewGitCommandAllowed(command, input) {
  const tokens = splitSimpleCommand(command)
  if (!tokens || tokens[0] !== 'git' || !READ_ONLY_GIT.has(tokens[1])) return false
  if (!['diff', 'show', 'cat-file', 'merge-base', 'rev-parse', 'status', 'ls-files', 'log', 'name-rev'].includes(tokens[1])) return false
  const joined = tokens.slice(2).join(' ')
  if (tokens[1] === 'status' || tokens[1] === 'ls-files') return true
  return joined.includes(input.base) || joined.includes(input.head)
}

export function outputText(value) {
  if (!value || value.kind !== 'foreground' || !Array.isArray(value.output)) return ''
  return value.output
    .filter(block => block && block.type === 'text' && typeof block.text === 'string')
    .map(block => block.text)
    .join('')
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
    ledger: config?.ledgerPath ? resolve(config.ledgerPath) : join(root, 'usage-ledger.jsonl'),
    mutationLock: config?.mutationLockPath ? resolve(config.mutationLockPath) : join(root, 'mutation-lock.json'),
  }
}

export function filesystemRoot(path) {
  return parse(resolve(path)).root
}
