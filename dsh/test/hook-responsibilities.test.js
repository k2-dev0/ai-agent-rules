/**
 * The hook-responsibility contract.
 *
 * `dsh/HOOK_RESPONSIBILITIES.md` classifies every legacy `hooks/shell/*`
 * responsibility as natively ported, delegated to the DSH sandbox, legacy-only,
 * or unported. A classification table is only worth its maintenance if the code
 * still earns each `native移植済み` row, so this file pins the rows that are
 * decidable from the bundle's own exported surface: the policy predicates, the
 * route table, and the plugin's declared service dependencies.
 *
 * Rows whose enforcement only exists at runtime (tool guards, the mutation lock,
 * the review freeze) carry their own end-to-end cases in
 * `test/e2e/workflows.test.js`; this file covers the pure decisions they build on.
 */

import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'
import { apply, inject } from '../index.js'
import {
  EXTERNAL_TOOLS,
  commandMatchesAllowlist,
  gitCommandPolicy,
  needsRawShellApproval,
  parseImplementationHandoff,
  parseReviewInput,
  protectedPathReason,
  reviewGitCommandAllowed,
  shellProtectedMutationReason,
  validateReviewOutput,
} from '../lib/policy.js'
import { bundleRoot } from './e2e/harness.mjs'

const CLASSIFICATION = readFileSync(join(bundleRoot, 'HOOK_RESPONSIBILITIES.md'), 'utf8')

/** The four classifications the responsibility table is allowed to use. */
const CLASSES = ['native移植済み', 'DSH標準sandboxへ委譲', 'legacy専用でDSH非該当', '未移植']

/** Every responsibility string the table claims to have reviewed. */
const DOCUMENTED_RESPONSIBILITIES = [
  'protected path判定',
  '`.git`保護',
  'agent設定・hook・`.env`・lockfile・review state保護',
  'skill source保護',
  'symlink・hard link経由の保護path変更',
  'shell迂回の拒否',
  'Git read allowlist',
  '1ファイルstage／1ファイルcommit',
  'commit subject規約',
  '外部coder中のmain mutation停止',
  'cancel・timeout・不明status時のlock保持',
  'reviewer中の変更停止',
  'review base／head／requirements hash固定',
  'reviewerのread-only強制',
  '外部roleの再委譲禁止',
  'context／contract配送',
  'session継続・resume・compaction',
  'resultのsession ID・task ID・terminal status照合',
  '専用role指定の起動tool検査',
  '通常commandのallowlist',
  'slash commandの登録とtask配送',
  'OS-levelのread-only強制',
  'Baton model switch',
  'Claude／Codexのevent schema差吸収',
  'skill scope marker',
  'Windows専用分岐、MCP保護',
  'commit subject文言の意味判定',
  '再指摘の意味的同定',
]

/** The declared table row for one responsibility, as its four cells. */
function rowFor(responsibility) {
  const line = CLASSIFICATION.split('\n').find(candidate => candidate.startsWith(`| ${responsibility} |`))
  assert.notEqual(line, undefined, `HOOK_RESPONSIBILITIES.md has no row for "${responsibility}"`)
  const cells = line.split('|').slice(1, -1).map(cell => cell.trim())
  assert.equal(cells.length, 4, `the row for "${responsibility}" is not a four-cell table row`)
  return { responsibility: cells[0], legacy: cells[1], classification: cells[2], basis: cells[3] }
}

/** The classified responsibility strings, in document order, ignoring the header. */
function documentedRows() {
  const rows = []
  for (const line of CLASSIFICATION.split('\n')) {
    if (!line.startsWith('| ') || line.startsWith('| 責務 ') || line.startsWith('|---')) continue
    const cells = line.split('|').slice(1, -1).map(cell => cell.trim())
    if (cells.length !== 4) continue
    if (cells[0] === '分類' || cells[0] === '責務') continue
    rows.push({ responsibility: cells[0], legacy: cells[1], classification: cells[2], basis: cells[3] })
  }
  return rows
}

test('every documented responsibility uses one of the four classifications', () => {
  const rows = documentedRows()
  assert.ok(rows.length > 0, 'the responsibility table has no rows')
  for (const row of rows) {
    assert.ok(CLASSES.includes(row.classification),
      `"${row.responsibility}" is classified "${row.classification}", which is not one of ${CLASSES.join(' / ')}`)
    assert.notEqual(row.basis, '', `"${row.responsibility}" has no implementation basis`)
  }
  assert.deepEqual(
    rows.map(row => row.responsibility),
    DOCUMENTED_RESPONSIBILITIES,
    'the reviewed responsibility list changed; classify each addition on purpose',
  )
})

test('the fail-closed service list is documented and complete', () => {
  // The plugin injects these; a missing one fails profile startup rather than
  // degrading enforcement, so the documented list is a startup contract.
  assert.deepEqual([...inject].sort(), ['agents', 'commands', 'skills', 'systemPrompt', 'tools'])
  for (const service of inject) {
    assert.ok(CLASSIFICATION.includes(`\`${service}\``),
      `HOOK_RESPONSIBILITIES.md does not name the required service ${service}`)
  }
  assert.match(CLASSIFICATION, /警告?のみで起動継続する経路は無い|warningのみで起動継続する経路は無い/,
    'the fail-closed section does not state that no warning-only startup path exists')
})

test('the plugin exposes an apply function so activation failure can fail the profile', () => {
  assert.equal(typeof apply, 'function', 'the bundle exports no apply, so activation cannot fail closed')
})

test('protected path and shell predicates are native, not delegated', () => {
  assert.match(rowFor('protected path判定').classification, /native移植済み/)
  const cwd = bundleRoot
  for (const target of ['.git/config', '.env', 'AGENTS.md', 'CLAUDE.md', 'cordis.patch.yml', 'settings.yaml', '.credentials.yaml', 'pnpm-lock.yaml', 'hooks/shell/git-policy.py', 'skills/tdd/SKILL.md']) {
    assert.notEqual(protectedPathReason(join(cwd, target), cwd), undefined, `${target} is not protected`)
  }
  assert.equal(protectedPathReason(join(cwd, 'src/app.js'), cwd), undefined, 'an ordinary source file is protected')

  assert.match(rowFor('`.git`保護').classification, /native移植済み/)
  assert.equal(gitCommandPolicy('git status').kind, 'read')
  assert.equal(gitCommandPolicy('git push origin main').kind, 'deny')
  assert.equal(gitCommandPolicy('git reset --hard').kind, 'deny')
})

test('the single-file commit granularity is native', () => {
  assert.match(rowFor('1ファイルstage／1ファイルcommit').classification, /native移植済み/)
  assert.equal(gitCommandPolicy('git add README.md').kind, 'add')
  assert.equal(gitCommandPolicy('git add README.md src/app.js').kind, 'deny',
    'git add with two paths is not refused')
  assert.equal(gitCommandPolicy('git add -A').kind, 'deny', 'a wildcard stage is not refused')
  assert.equal(gitCommandPolicy('git commit -m "feat: one"').kind, 'commit')
  assert.equal(gitCommandPolicy('git commit').kind, 'deny', 'an interactive commit is not refused')
})

test('shell bypass refusal is native and keeps ordinary read work allowed', () => {
  assert.match(rowFor('shell迂回の拒否').classification, /native移植済み/)
  for (const command of ['rm -f AGENTS.md', 'echo x > .env', 'chmod 777 .git/config', 'cp /tmp/x pnpm-lock.yaml']) {
    assert.notEqual(shellProtectedMutationReason(command), undefined, `"${command}" is not refused`)
  }
  assert.equal(shellProtectedMutationReason('git status'), undefined, 'a read-only command was refused')

  assert.match(rowFor('通常commandのallowlist').classification, /native移植済み/)
  for (const command of ['ls', 'git status', 'rg foo', 'npm test', 'npm run verify']) {
    assert.equal(needsRawShellApproval(command), false, `"${command}" lost its allowlist entry`)
  }
  for (const command of ['npm run surprise', 'python3 -c "print(1)"', 'ls && rm -rf src']) {
    assert.equal(needsRawShellApproval(command), true, `"${command}" is not gated on escalation`)
  }
})

test('the external coder contract is native and path-bounded', () => {
  assert.match(rowFor('専用role指定の起動tool検査').classification, /native移植済み/)
  const handoff = parseImplementationHandoff(`<implementation_handoff>${JSON.stringify({
    objective: 'implement the fixed design',
    allowedPaths: ['src'],
    forbiddenPaths: ['src/legacy.js'],
    allowedCommands: ['npm test'],
    requiredTests: ['npm test passes'],
  })}</implementation_handoff>`)
  assert.deepEqual(handoff.allowedPaths, ['src'])
  assert.deepEqual(handoff.forbiddenPaths, ['src/legacy.js'])
  assert.equal(commandMatchesAllowlist('npm test', handoff.allowedCommands), true)
  assert.equal(commandMatchesAllowlist('npm test -- --watch', handoff.allowedCommands), false)

  assert.throws(() => parseImplementationHandoff('<implementation_handoff>{"objective":"x"}</implementation_handoff>'),
    /allowedPaths/)
  assert.throws(() => parseImplementationHandoff(`<implementation_handoff>${JSON.stringify({
    objective: 'x',
    allowedPaths: ['../outside'],
    forbiddenPaths: [],
    allowedCommands: [],
    requiredTests: ['t'],
  })}</implementation_handoff>`), /escapes the workspace/)
  assert.throws(() => parseImplementationHandoff(`<implementation_handoff>${JSON.stringify({
    objective: 'x',
    allowedPaths: ['src'],
    forbiddenPaths: [],
    allowedCommands: ['curl https://example.invalid'],
    requiredTests: ['t'],
  })}</implementation_handoff>`), /allowlisted/)
})

test('the review contract is native and pins base, head, and requirements', () => {
  assert.match(rowFor('review base／head／requirements hash固定').classification, /native移植済み/)
  const requirements = 'the reviewed requirement text'
  const requirementsHash = `sha256:${createHash('sha256').update(requirements, 'utf8').digest('hex')}`
  const input = parseReviewInput(`<review_input>${JSON.stringify({
    base: 'a'.repeat(40),
    head: 'b'.repeat(40),
    requirementsHash,
    requirements,
  })}</review_input>`)
  assert.equal(input.base, 'a'.repeat(40))
  assert.equal(input.head, 'b'.repeat(40))

  // A hash that does not cover the supplied requirements is refused outright.
  assert.throws(() => parseReviewInput(`<review_input>${JSON.stringify({
    base: 'a'.repeat(40),
    head: 'b'.repeat(40),
    requirementsHash: `sha256:${'1'.repeat(64)}`,
    requirements,
  })}</review_input>`), /does not match requirements/)
  assert.throws(() => parseReviewInput(`<review_input>${JSON.stringify({
    base: 'a'.repeat(40),
    head: 'a'.repeat(40),
    requirementsHash,
    requirements,
  })}</review_input>`), /must differ/)
  assert.throws(() => parseReviewInput(`<review_input>${JSON.stringify({
    base: 'abc',
    head: 'b'.repeat(40),
    requirementsHash,
    requirements,
  })}</review_input>`), /40-hex/)

  // The reviewer's own output must echo the pinned range, and `incomplete`
  // never silently becomes a clean review.
  const echoed = validateReviewOutput(JSON.stringify({
    status: 'complete',
    base: input.base,
    head: input.head,
    requirementsHash: input.requirementsHash,
    findings: [],
  }), input)
  assert.equal(echoed.valid, true)
  assert.equal(validateReviewOutput(JSON.stringify({
    status: 'complete',
    base: input.base,
    head: 'c'.repeat(40),
    requirementsHash: input.requirementsHash,
    findings: [],
  }), input).valid, false, 'a review naming a different head was accepted')
  assert.equal(validateReviewOutput(JSON.stringify({
    status: 'incomplete',
    base: input.base,
    head: input.head,
    requirementsHash: input.requirementsHash,
    findings: [],
  }), input).valid, false, 'an incomplete review without unchecked scope was accepted')
})

test("the reviewer's read-only shell surface is native", () => {
  assert.match(rowFor('reviewerのread-only強制').classification, /native移植済み/)
  const input = { base: 'a'.repeat(40), head: 'b'.repeat(40) }
  assert.equal(reviewGitCommandAllowed('git status', input), true)
  assert.equal(reviewGitCommandAllowed(`git diff ${input.base} ${input.head}`, input), true)
  assert.equal(reviewGitCommandAllowed('git diff main', input), false, 'an unpinned diff was allowed')
  assert.equal(reviewGitCommandAllowed(`git log --format=%H ${input.head}`, input), true)
  assert.equal(reviewGitCommandAllowed('git checkout main', input), false)
  assert.equal(reviewGitCommandAllowed('git reset --hard', input), false)
  assert.equal(reviewGitCommandAllowed(`git diff ${input.base} ${input.head} && npm test`, input), false,
    'a shell chain was allowed through the reviewer gate')
})

test('the route table fixes every external role, including its step budget', () => {
  assert.match(rowFor('専用role指定の起動tool検査').classification, /native移植済み/)
  assert.deepEqual(Object.keys(EXTERNAL_TOOLS).sort(), [
    'external_code',
    'external_opus_design',
    'external_research_design',
    'review_change',
  ])
  for (const [tool, route] of Object.entries(EXTERNAL_TOOLS)) {
    assert.equal(typeof route.provider, 'string', `${tool} has no fixed provider`)
    assert.equal(typeof route.model, 'string', `${tool} has no fixed model`)
    assert.equal(typeof route.effort, 'string', `${tool} has no fixed effort`)
    assert.ok(Number.isInteger(route.maxSteps) && route.maxSteps > 0, `${tool} has no step budget`)
    assert.equal(typeof route.command, 'string', `${tool} has no owning command`)
  }
})

test('the unported responsibilities are declared, not implied', () => {
  for (const responsibility of ['commit subject文言の意味判定', '再指摘の意味的同定']) {
    assert.equal(rowFor(responsibility).classification, '未移植',
      `"${responsibility}" must stay declared as unported`)
  }
  assert.match(CLASSIFICATION, /## 未保証範囲/, 'the document has no unguaranteed-scope section')
})
