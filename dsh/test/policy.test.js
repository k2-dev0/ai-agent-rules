import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { linkSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import {
  EXTERNAL_TOOLS,
  commandMatchesAllowlist,
  commandTokens,
  currentTurn,
  gitCommandPolicy,
  isInsideAllowedPath,
  isExternalCodeCommand,
  latestDirectUserMessage,
  needsRawShellApproval,
  parseImplementationHandoff,
  parseReviewInput,
  protectedPathReason,
  reviewGitCommandAllowed,
  shellProtectedMutationReason,
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

test('only a direct user message can carry a routing command token', () => {
  const direct = session([{ text: '/external-plan' }])
  assert.deepEqual(latestDirectUserMessage(direct).commands, ['external-plan'])
  const injected = session([{ source: 'tool', text: '/review' }])
  assert.equal(latestDirectUserMessage(injected), undefined)
  const skill = session([{ source: 'skill', text: '/external-code' }])
  assert.equal(latestDirectUserMessage(skill), undefined)
  assert.deepEqual(commandTokens('/review now'), ['review'])
  assert.deepEqual(commandTokens('run the /reviewer'), [])
})

test('the current turn is read from durable turn events', () => {
  assert.equal(currentTurn({
    snapshotEvents: () => [{ type: 'turn/start', data: { turn: 4 } }, { type: 'step/start', data: { turn: 4, step: 1 } }],
  }), 4)
  assert.equal(currentTurn({
    snapshotEvents: () => [{ type: 'turn/start', data: { turn: 4 } }, { type: 'turn/end', data: { turn: 4, reason: 'completed' } }],
  }), undefined)
  assert.equal(currentTurn({}), undefined)
})

test('every external tool is reachable only through one registered command', () => {
  const commands = Object.entries(EXTERNAL_TOOLS).map(([tool, route]) => [tool, route.command])
  assert.deepEqual(commands, [
    ['external_research_design', 'external-plan'],
    ['external_opus_design', 'opus-plan'],
    ['external_code', 'external-code'],
    ['review_change', 'review'],
  ])
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
  assert.equal(needsRawShellApproval('npm run verify'), false, 'repository verify scripts stay runnable')
  assert.equal(needsRawShellApproval('npm run verify:e2e'), false)
  assert.equal(needsRawShellApproval('npm run check'), false)
  assert.equal(needsRawShellApproval('npm run build'), false)
  assert.equal(needsRawShellApproval('npm run surprise'), true, 'arbitrary script names remain raw shell')
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
  assert.equal(reviewGitCommandAllowed(`git log --oneline ${base}..${head}`, input), true)
  assert.equal(reviewGitCommandAllowed('git status', input), true)
  assert.equal(reviewGitCommandAllowed('git status --porcelain', input), true)
  assert.equal(reviewGitCommandAllowed('git ls-files', input), true)
  assert.equal(reviewGitCommandAllowed('git checkout main', input), false)
  assert.equal(reviewGitCommandAllowed('git reset --hard HEAD', input), false)
  assert.equal(reviewGitCommandAllowed('git status --delete', input), false)
  assert.equal(reviewGitCommandAllowed('git log --oneline --all', input), false, 'a read that names neither SHA is unpinned')
  assert.equal(reviewGitCommandAllowed('git diff --stat', input), false)
  assert.equal(reviewGitCommandAllowed(`git diff ${base} ${head} && rm -rf src`, input), false)
  assert.equal(reviewGitCommandAllowed(`git show ${head}`, input), true)
  assert.equal(validateReviewOutput(JSON.stringify({ status: 'complete', base, head, requirementsHash, findings: [] }), input).valid, true)
  assert.equal(validateReviewOutput(JSON.stringify({ status: 'incomplete', base, head, requirementsHash, findings: [] }), input).valid, false)
  assert.throws(() => parseReviewInput(`<review_input>${JSON.stringify({ base, head, requirementsHash: `sha256:${'0'.repeat(64)}`, requirements })}</review_input>`), /does not match/)
})
