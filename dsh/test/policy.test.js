import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { linkSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import {
  budgetTier,
  calculateCost,
  commandMatchesAllowlist,
  gitCommandPolicy,
  isInsideAllowedPath,
  isExternalCodeCommand,
  latestDirectUserMessage,
  needsRawShellApproval,
  parseImplementationHandoff,
  parseReviewInput,
  protectedPathReason,
  reviewGitCommandAllowed,
  routingDecision,
  routingFlags,
  shellProtectedMutationReason,
  utcMonth,
  validateDesignHandoff,
  validateReviewOutput,
} from '../lib/policy.js'

function session(messages, depth = 0) {
  return {
    header: { delegationDepth: depth },
    snapshotEvents: () => [
      { type: 'turn/start', data: { turn: 1 } },
      ...messages.map(({ source = 'user', text, id = 'm' }) => ({
        type: 'user/message',
        data: { id, source: { kind: source }, content: [{ type: 'text', text }] },
      })),
    ],
  }
}

test('routing uses only the current direct user message', () => {
  const direct = session([{ text: '/external-plan' }])
  assert.equal(routingDecision('external_research_design', direct).allowed, true)
  assert.equal(routingDecision('external_code', direct).allowed, false)
  const injected = session([{ source: 'tool', text: '/review' }])
  assert.equal(routingDecision('review_change', injected).allowed, false)
  assert.equal(latestDirectUserMessage(injected), undefined)
})

test('routing rejects conflicts, recursion, repetition, and negation', () => {
  assert.equal(routingDecision('external_research_design', session([{ text: '/external-plan /opus-plan' }])).allowed, false)
  assert.equal(routingDecision('external_research_design', session([{ text: '/external-plan' }], 1)).allowed, false)
  assert.equal(routingDecision('external_research_design', session([{ text: '/external-plan' }]), true).allowed, false)
  assert.equal(routingFlags('GLMを使わないで調査して').externalPlan, false)
  assert.equal(routingFlags('GLM-5.3を使って調査と概要設計をして').externalPlan, true)
  assert.equal(routingFlags('GPT-6 Solでレビューして').review, true)
})

test('protected paths cover canonical aliases and hard links', () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-policy-'))
  mkdirSync(join(root, '.git'))
  writeFileSync(join(root, '.git', 'config'), 'x')
  symlinkSync(join(root, '.git'), join(root, 'alias'))
  assert.match(protectedPathReason('alias/config', root), /protected component/)
  assert.match(protectedPathReason('../outside/.env.local', root), /environment file/)
  assert.match(protectedPathReason('pnpm-lock.yaml', root), /protected file/)
  const original = join(root, 'ordinary.txt')
  writeFileSync(original, 'x')
  linkSync(original, join(root, 'hard.txt'))
  assert.match(protectedPathReason('hard.txt', root), /hard-linked/)
})

test('shell path guard allows reads and denies protected mutations', () => {
  assert.equal(shellProtectedMutationReason('sed -n 1,20p .codex/config.toml'), undefined)
  assert.match(shellProtectedMutationReason('rm .codex/config.toml'), /protected/)
  assert.match(shellProtectedMutationReason('printf x > .env'), /protected/)
  assert.equal(needsRawShellApproval('npm test'), false)
  assert.equal(needsRawShellApproval('python3 script.py'), true)
  assert.equal(needsRawShellApproval('rg foo . | head'), true)
})

test('git policy keeps read access and single-path mutations', () => {
  assert.deepEqual(gitCommandPolicy('git diff HEAD~1 HEAD'), { kind: 'read' })
  assert.deepEqual(gitCommandPolicy('git add -- src/a.ts'), { kind: 'add', path: 'src/a.ts' })
  assert.equal(gitCommandPolicy('git add a b').kind, 'deny')
  assert.equal(gitCommandPolicy('git reset --hard').kind, 'deny')
  assert.equal(gitCommandPolicy('git commit -m "feat: one"').kind, 'commit')
})

test('implementation handoff is structured and path bounded', () => {
  const handoff = parseImplementationHandoff(`before
<implementation_handoff>
{"objective":"implement","allowedPaths":["src"],"forbiddenPaths":["src/secret"],"allowedCommands":["npm test"],"requiredTests":["tests pass"]}
</implementation_handoff>`)
  assert.deepEqual(handoff.allowedPaths, ['src'])
  assert.equal(commandMatchesAllowlist('npm test', handoff.allowedCommands), true)
  assert.equal(isExternalCodeCommand('npm run typecheck'), true)
  assert.equal(isExternalCodeCommand('bash scripts/test.sh'), false)
  const root = mkdtempSync(join(tmpdir(), 'dsh-path-'))
  mkdirSync(join(root, 'src'))
  mkdirSync(join(root, 'src', 'secret'))
  assert.equal(isInsideAllowedPath('src/a.ts', root, handoff.allowedPaths, handoff.forbiddenPaths), true)
  assert.equal(isInsideAllowedPath('src/secret/a.ts', root, handoff.allowedPaths, handoff.forbiddenPaths), false)
  assert.throws(() => parseImplementationHandoff('<implementation_handoff>{"objective":"x","allowedPaths":["../x"],"forbiddenPaths":[],"allowedCommands":[],"requiredTests":["x"]}</implementation_handoff>'), /escapes/)
})

test('design handoff requires every ordered heading', async () => {
  const { DESIGN_HANDOFF_HEADINGS } = await import('../lib/policy.js')
  assert.equal(validateDesignHandoff(DESIGN_HANDOFF_HEADINGS.join('\ntext\n')).valid, true)
  assert.equal(validateDesignHandoff('# Design Handoff\n## 目的').valid, false)
})

test('review contract fixes SHAs and distinguishes incomplete', () => {
  const base = 'a'.repeat(40)
  const head = 'b'.repeat(40)
  const requirements = 'The change must preserve behavior.'
  const requirementsHash = `sha256:${createHash('sha256').update(requirements).digest('hex')}`
  const input = parseReviewInput(`<review_input>${JSON.stringify({ base, head, requirementsHash, requirements })}</review_input>`)
  assert.equal(reviewGitCommandAllowed(`git diff ${base} ${head}`, input), true)
  assert.equal(reviewGitCommandAllowed('git status', input), true)
  assert.equal(reviewGitCommandAllowed('git checkout main', input), false)
  assert.equal(validateReviewOutput(JSON.stringify({ status: 'complete', base, head, requirementsHash, findings: [] }), input).valid, true)
  assert.equal(validateReviewOutput(JSON.stringify({ status: 'incomplete', base, head, requirementsHash, findings: [] }), input).valid, false)
  assert.throws(() => parseReviewInput(`<review_input>${JSON.stringify({ base, head, requirementsHash: `sha256:${'0'.repeat(64)}`, requirements })}</review_input>`), /does not match/)
})

test('costs use disjoint cache fields and conservative rates', () => {
  const cost = calculateCost({
    inputTokens: 1_000_000,
    cacheReadTokens: 1_000_000,
    cacheWriteTokens: 1_000_000,
    outputTokens: 1_000_000,
    reasoningTokens: 500_000,
  }, 'zai', 'glm-5.3')
  assert.equal(cost, 7.46)
  assert.equal(budgetTier(99.99), 'normal')
  assert.equal(budgetTier(140), 'confirm')
  assert.equal(budgetTier(180), 'external-stop')
  assert.equal(budgetTier(200), 'absolute-stop')
  assert.match(utcMonth(Date.UTC(2026, 8, 30)), /^2026-09$/)
})
