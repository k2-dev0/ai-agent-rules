/**
 * The real DSH end-to-end run.
 *
 * Every assertion here is produced by the installed DSH `0.1.7-rc.1` CLI, by the
 * profile it boots, or by the in-profile probe those tests mount. The environment
 * is a throwaway `DSH_HOME`, a throwaway Git workspace, and a loopback mock
 * provider, so nothing reaches a real provider and nothing bills an account.
 *
 * `npm run verify` runs this file together with the unit suite.
 */

import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'
import { MOCK_CREDENTIAL, resolveDshBin, runDsh, webBootArgs } from './harness.mjs'
import { DISTRIBUTED_SKILLS, probePatch, setupWorkflowEnvironment } from './setup.mjs'
import { LEGACY_ROUTING_DOCS, LEGACY_SKILLS } from '../../lib/deploy-skills.js'

const ctx = await setupWorkflowEnvironment()
test.after(async () => { await ctx.cleanup() })

const PROTECTED_PATHS = ['.git/config', '.env', 'AGENTS.md', 'cordis.patch.yml', 'pnpm-lock.yaml', 'settings.yaml']
const PROTECTED_SHELL = ['rm -f AGENTS.md', 'echo x > .env', 'chmod 777 .git/config', 'cp /tmp/x pnpm-lock.yaml']
const ALLOWED_SHELL = ['git status', 'npm test']
// Commands the policy refuses only because no sandbox escalation accompanies
// them. Each one is also asserted to be allowed once that escalation is given,
// so the case proves the escalation gate. `git add` with two paths is a
// different rule (exactly one staged path) and is covered by the git-mutation
// case instead.
const APPROVAL_SHELL = ['npm run surprise', 'python3 -c "print(1)"', 'git add README.md']
const TASK_TEXT = 'E2E task text for the routing intent'

/**
 * Run every end-to-end group in one profile boot.
 *
 * One boot keeps the suite fast. The probe is responsible for isolating groups
 * from each other: it gives every case its own agents, so one failure cannot
 * cascade into "inactive context" for the cases that follow.
 */
let probed
function runProbe() {
  // Memoized: expectCases calls this once per assertion group, and without the
  // cache every group installed and booted the profile again — four boots
  // instead of one, which dominated the suite runtime.
  if (probed !== undefined) return probed
  const specPath = ctx.writeSpec('workflows', {
    workspace: ctx.env.workdir,
    commands: ['external-plan', 'opus-plan', 'external-code', 'review'],
    taskText: TASK_TEXT,
    expectedSkills: DISTRIBUTED_SKILLS,
    loadSkills: ['tdd', 'preflight', 'unwind', 'dictionary', 'rebase'],
    invocationExpectations: [
      { name: 'tdd', modelInvocable: true, userInvocable: true },
      { name: 'e2e', modelInvocable: false, userInvocable: true },
      { name: 'preflight', modelInvocable: true, userInvocable: false },
      // `meeting` is an explicit `$meeting` flow: its frontmatter sets
      // `disable-model-invocation`, so only a user invocation reaches it.
      { name: 'meeting', modelInvocable: false, userInvocable: true },
    ],
    legacySkills: LEGACY_SKILLS,
    protectedPaths: PROTECTED_PATHS,
    protectedShellCommands: PROTECTED_SHELL,
    allowedShellCommands: ALLOWED_SHELL,
    approvalShellCommands: APPROVAL_SHELL,
    // `review_change` pins the current HEAD to the supplied head, so the probe
    // needs the exact commits of the disposable workspace.
    reviewBase: ctx.base,
    reviewHead: ctx.head,
    reviewRequirements: ctx.requirements,
    // One-shot consumption is a durable fact: the probe reads it back from the
    // state the policy plugin persists, because a route tool the loopback mock
    // cannot complete may still consume its intent.
    intentStatePath: join(ctx.env.home, 'dsh-main-policy', 'routing-intents.json'),
    // Recorded by the probe, not asserted: whether the booted tree can reach
    // this provider is an environment fact, and the turn-based cases report how
    // they ended their turn rather than failing on it.
    mockBaseURL: ctx.mock.baseURL,
    // A case is bounded, but the bounds must leave room for a turn to close:
    // `turn-end-closes-the-intent` waits on the turn's own end, so its case
    // budget has to exceed that wait.
    caseTimeoutMs: 30_000,
    turnCloseWaitMs: 20_000,
    groups: ['commands', 'instructions', 'skills', 'guards'],
  })
  const patchPath = ctx.writePatch('workflows', probePatch(specPath))
  const reportPath = join(ctx.env.root, 'workflows.report.json')
  const booted = runDsh(ctx.env, webBootArgs(ctx.env, [ctx.routePatchPath, patchPath]), {
    env: { DSH_E2E_PROBE_REPORT: reportPath },
    timeoutMs: 180_000,
  })
  const report = existsSync(reportPath) ? JSON.parse(readFileSync(reportPath, 'utf8')) : undefined
  probed = { booted, report, results: report?.results ?? [] }
  return probed
}

/** Assert every named case ran and passed in the report produced for its group. */
function expectCases(results, ...ids) {
  assert.ok(results.length > 0, 'the probe produced no results for this group')
  const byId = new Map(results.map(entry => [entry.id, entry]))
  const problems = []
  for (const id of ids) {
    const entry = byId.get(id)
    if (!entry) problems.push(`  - ${id}: the probe did not run this case`)
    else if (!entry.ok) problems.push(`  - ${id}: ${entry.detail}`)
  }
  for (const entry of results) {
    if (!entry.ok && !ids.includes(entry.id)) problems.push(`  - ${entry.id}: ${entry.detail}`)
  }
  assert.deepEqual(problems, [], `end-to-end failures:\n${problems.join('\n')}`)
}

test('e2e: the composed profile pins the main route, four role routes, and the policy plugin', () => {
  const dumped = runDsh(ctx.env, ['--profile', ctx.env.profile, '--dump-config'])
  assert.equal(dumped.status, 0, `--dump-config failed: ${dumped.stderr || dumped.stdout}`)
  const text = dumped.stdout
  writeFileSync(join(ctx.env.root, 'dump.yml'), text, 'utf8')

  assert.match(text, /id: agent-default-model[\s\S]{0,200}provider: deepseek-official[\s\S]{0,200}model: deepseek-flash/,
    'the main route is not deepseek-official/deepseek-flash')

  for (const [tool, provider, model, effort, maxTokens, toolWord] of [
    ['external_research_design', 'zai', 'glm-5.3', 'max', '12000', 'read'],
    ['external_opus_design', 'anthropic', 'claude-opus-5-5', 'high', '12000', 'read'],
    ['external_code', 'zai', 'glm-5.3', 'high', '16000', 'write'],
    ['review_change', 'openai', 'gpt-6-sol', 'high', '8000', 'bash'],
  ]) {
    const block = new RegExp(
      `toolName: ${tool}`
      + `[\\s\\S]{0,700}?provider: ${provider}`
      + `[\\s\\S]{0,200}?model: ${model}`
      + `[\\s\\S]{0,200}?reasoningEffort: ${effort}`
      + `[\\s\\S]{0,200}?maxTokens: ${maxTokens}`
      + `[\\s\\S]{0,500}?- ${toolWord}`,
    )
    assert.match(text, block, `${tool} is not pinned to its provider/model/effort/maxTokens/toolFilter`)
    assert.match(text, new RegExp(`toolName: ${tool}[\\s\\S]{0,600}?maxDepth: 1`), `${tool} has no maxDepth: 1`)
    assert.match(text, new RegExp(`toolName: ${tool}[\\s\\S]{0,600}?enableRunInBackground: false`),
      `${tool} can be started in the background`)
    assert.match(text, new RegExp(`toolName: ${tool}[\\s\\S]{0,600}?backgroundMode: one-shot`),
      `${tool} is not one-shot`)
    assert.doesNotMatch(text, new RegExp(`toolName: ${tool}[\\s\\S]{0,900}?modelSelectionSettings: true`),
      `${tool} exposes provider/model/effort selection to the model`)
  }

  assert.match(text, /name: '@kaikojima\/dsh-main-policy'[\s\S]{0,400}?stateRoot/,
    'the policy plugin has no state root')
  // The bundle owns its skill provider, so the composed profile must not carry a
  // `dsh-main-skill-filesystem` insert row pointing at a `skills/` directory the
  // installed package does not ship. The provider itself is asserted at runtime
  // by the skill catalog cases, and statically in `verify.mjs` against the bundle.
  assert.doesNotMatch(text, /dsh-main-skill-filesystem/,
    'the profile still inserts a skill filesystem plugin the bundle does not ship')
  assert.match(text, /- id: web-startup[\s\S]{0,200}?- dshMainPolicy/,
    'the web surface does not depend on the policy service')
  assert.equal(/\bbudget\b|\bspend\b|\bcost\b|\bprice\b|\bbilling\b/i.test(text), false,
    'the composed profile carries a budget or cost concept')
})

test('e2e: no bundle-declared configuration pins a source-repository path', () => {
  const profileDir = join(ctx.env.home, 'profiles', ctx.env.profile)
  const manifest = JSON.parse(readFileSync(join(profileDir, 'package.json'), 'utf8'))
  assert.deepEqual(manifest.dsh.profile.bundles, [
    '@deepseek-ai/dsh-base',
    '@deepseek-ai/dsh-web-app',
    '@kaikojima/dsh-main-policy',
  ])
  const userPatch = readFileSync(join(profileDir, 'cordis.patch.yml'), 'utf8')
  assert.equal(/\/(?:Users|home)\//.test(userPatch), false, 'the profile patch pins an absolute path')
  const bundlePatch = readFileSync(join(ctx.bundleRoot, 'cordis.patch.yml'), 'utf8')
  assert.equal(/\/(?:Users|home)\//.test(bundlePatch), false, 'the bundle declares an absolute path')
})

test('e2e: skills deploy into a DSH-discovered root and keep their invocation policy', () => {
  assert.equal(ctx.skills.deployed.length, DISTRIBUTED_SKILLS.length)
  assert.deepEqual(
    ctx.skills.deployed.map(skill => skill.name).sort(),
    [...DISTRIBUTED_SKILLS].sort(),
  )
  const byName = new Map(ctx.skills.deployed.map(skill => [skill.name, skill]))
  assert.equal(byName.get('e2e').modelInvocable, false, 'the e2e skill must stay explicit-invocation only')
  assert.equal(byName.get('preflight').userInvocable, false, 'preflight must stay model-only')
  assert.equal(byName.get('tdd').modelInvocable, true)

  const root = join(ctx.env.workdir, '.agents', 'skills')
  for (const legacy of LEGACY_SKILLS) {
    assert.equal(existsSync(join(root, legacy)), false, `${legacy} must not be published to DSH`)
  }
  const published = readdirSync(root)
  for (const doc of LEGACY_ROUTING_DOCS) {
    assert.equal(published.includes(doc), false, `${doc} was published as if it were a skill`)
  }
})

test('e2e: the four commands, one-shot intents, and the routing boundary behave', () => {
  expectCases(
    runProbe().results,
    'command-registered:external-plan',
    'command-registered:opus-plan',
    'command-registered:external-code',
    'command-registered:review',
    'unknown-command-is-not-admitted',
    'external-tool-without-command-is-denied',
    'external-tool-without-command-is-required-to-be-started-by-a-command',
    'command-records-intent-and-delivers-task-text',
    'external-tool-uses-its-intent-once',
    'plan-command-conflict-is-denied',
    'review-base-head-hash-mismatch-is-rejected',
    'tool-output-text-cannot-open-a-route',
    'nested-agent-cannot-start-an-external-route',
    'turn-end-closes-the-intent',
  )
})

test('e2e: the DSH instructions are injected and legacy routing is not applied', () => {
  expectCases(runProbe().results, 'dsh-instructions-are-injected', 'legacy-routing-is-not-applied')
})

test('e2e: the skill catalog is visible and skill bodies load', () => {
  expectCases(
    runProbe().results,
    ...DISTRIBUTED_SKILLS.map(skill => `skill-catalog:${skill}`),
    ...['tdd', 'preflight', 'unwind', 'dictionary', 'rebase'].map(skill => `skill-load:${skill}`),
    ...['tdd', 'e2e', 'preflight', 'meeting'].map(skill => `skill-policy:${skill}`),
    'no-legacy-routing-skill-is-model-invocable',
  )
})

test('e2e: protected paths and shell bypasses are denied', () => {
  expectCases(
    runProbe().results,
    ...PROTECTED_PATHS.flatMap(path => [`protected-write:${path}`, `protected-edit:${path}`]),
    ...PROTECTED_SHELL.map(command => `protected-shell:${command}`),
    'symlink-to-protected-path-is-denied',
    'hard-link-mutation-is-denied',
    ...ALLOWED_SHELL.map(command => `allowed-shell:${command}`),
    ...APPROVAL_SHELL.map(command => `escalation-required:${command}`),
    'git-mutation-requires-single-staged-file',
  )
})

test('e2e: corrupt policy state fails the reboot closed and no intent stays open', () => {
  const stateDir = join(ctx.env.home, 'dsh-main-policy')
  const statePath = join(stateDir, 'routing-intents.json')
  assert.equal(existsSync(statePath), true, 'the probe run did not persist routing-intent state')
  const live = JSON.parse(readFileSync(statePath, 'utf8'))
  assert.equal(live.version, 1)
  assert.ok(live.intents.length > 0, 'no routing intent was recorded at all')
  assert.equal(live.intents.some(intent => intent.status === 'open'), false,
    'a routing intent stayed open after the run')

  writeFileSync(statePath, '{ this is not json', 'utf8')
  try {
    const booted = runDsh(ctx.env, webBootArgs(ctx.env, [ctx.routePatchPath]), {
      timeoutMs: 60_000,
    })
    assert.notEqual(booted.status, 0, 'the profile booted with corrupt policy state')
    const diagnosis = join(stateDir, 'activation-error.txt')
    assert.equal(existsSync(diagnosis), true, 'the failure left no diagnosable record')
    assert.match(readFileSync(diagnosis, 'utf8'), /not valid JSON|routing-intent state/i,
      'the failure did not identify the corrupt state')
  } finally {
    writeFileSync(statePath, `${JSON.stringify(live, undefined, 2)}\n`, 'utf8')
  }

  const disabled = ctx.writePatch('policy-disabled', [
    '- id: dsh-main-policy',
    '  disabled: true',
    '',
  ].join('\n'))
  const withoutPolicy = runDsh(ctx.env, ['--profile', ctx.env.profile, '--patch', disabled, '--dump-config'])
  assert.equal(/provide\('dshMainPolicy'/.test(withoutPolicy.stdout), false,
    'the policy service is still provided while the plugin is disabled')
})

test('e2e: no credential value or task text reaches policy state or profile logs', () => {
  const offenders = []
  const stateDir = join(ctx.env.home, 'dsh-main-policy')
  if (existsSync(stateDir)) {
    for (const entry of readdirSync(stateDir)) {
      const full = join(stateDir, entry)
      if (!statSync(full).isFile()) continue
      const text = readFileSync(full, 'utf8')
      if (text.includes(MOCK_CREDENTIAL)) offenders.push(`${entry}: credential value`)
      if (/sk-[A-Za-z0-9_-]{16,}/.test(text)) offenders.push(`${entry}: api-key shape`)
      if (text.includes(TASK_TEXT)) offenders.push(`${entry}: task text`)
    }
  }
  assert.deepEqual(offenders, [], `policy state leaked secrets: ${offenders.join('; ')}`)

  const logDir = join(ctx.env.home, 'profiles', ctx.env.profile, '.plugin-manager', 'logs')
  if (existsSync(logDir)) {
    for (const dir of readdirSync(logDir)) {
      const log = join(logDir, dir, 'pnpm.log')
      if (!existsSync(log)) continue
      assert.equal(readFileSync(log, 'utf8').includes(MOCK_CREDENTIAL), false,
        `a credential value leaked into ${log}`)
    }
  }
})

test('e2e: the DSH binary under test is the pinned version', () => {
  assert.equal(ctx.version, '0.1.7-rc.1')
  assert.ok(resolveDshBin().includes('@deepseek-ai'))
})
