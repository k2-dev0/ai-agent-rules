/**
 * Prepare one end-to-end environment.
 *
 * Everything the real-DSH tests share is created here: a throwaway `DSH_HOME`
 * with the profile installed from this bundle, a throwaway Git workspace with
 * two commits, the loopback mock provider, and the `--patch` overlays that point
 * the profile at that mock.
 *
 * The workspace deliberately has **no** `.agents/skills` or `.dsh/skills` root.
 * The DSH filesystem provider outranks this bundle's provider (project-agents
 * rank 200 against the bundle's 350), so deploying the distribution's skills
 * into the workspace first would make every catalog assertion pass on files the
 * test copied, never on the provider the bundle ships. Leaving the roots absent
 * is what makes the skill cases real.
 */

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import {
  assertDshVersion,
  bundleRoot,
  createEnvironment,
  createGitWorkspace,
  initializeProfile,
  installBundle,
  MOCK_CREDENTIAL_ENV,
  removeIterationHelpers,
  repositoryRoot,
} from './harness.mjs'
import { startMockProvider } from './mock-provider.mjs'
import { discoverDistributionSkills, distributionSkillsRoot } from '../../lib/distribution-skills.js'

/**
 * Skills this distribution publishes to DSH.
 *
 * Derived from the bundle's own provider rather than written out, so the tests
 * assert the shipped catalog instead of a second copy of it.
 */
export const DISTRIBUTED_SKILLS = Object.freeze(
  discoverDistributionSkills(distributionSkillsRoot()).map(candidate => candidate.name),
)

/** The Design Handoff contract the research routes must produce. */
export const DESIGN_HANDOFF_HEADINGS = [
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
]

export const DESIGN_HANDOFF = DESIGN_HANDOFF_HEADINGS.map(heading => `${heading}\n本文`).join('\n\n')

/**
 * The mock provider overlay, applied with `--patch` and never part of the bundle.
 *
 * One patch row replaces a row's whole config, so restating `llm-pi-ai` here
 * would drop the real `zai`, `anthropic`, and `openai` route declarations and
 * leave an external route with no adapter — its tool call then fails during
 * provider resolution, before the policy installs the lock that call is supposed
 * to take. Pointing those same provider ids at the loopback mock keeps every
 * route reachable with no credential and still no real provider.
 */
export function mockRoutePatch(baseURL) {
  const loopback = (provider, modelIds) => [
    `      ${provider}:`,
    `        apiKeyEnv: ${MOCK_CREDENTIAL_ENV}`,
    '        api: openai-completions',
    `        baseURL: ${baseURL}`,
    '        models:',
    ...modelIds.flatMap(id => [
      `          - id: ${id}`,
      `            name: ${id}`,
      '            contextWindow: 200000',
      '            maxTokens: 8192',
      '            input: [text]',
      // The bundle pins a `reasoningEffort` on every external route, so the mock
      // has to advertise the same efforts or route resolution refuses the child
      // before the policy can install the lock that call is meant to take.
      '            reasoningEfforts:',
      '              low: low',
      '              high: high',
      '              max: max',
    ]),
    '        retryPolicy:',
    '          mode: normal',
    '          maxRetries: 0',
  ].join('\n')

  return [
    '# E2E-only overlay: a loopback mock provider. Never part of the bundle.',
    '- id: agent-default-model',
    '  config:',
    '    provider: mock',
    '    model: mock-1',
    '- id: llm-pi-ai',
    '  config:',
    '    providers:',
    loopback('mock', ['mock-1']),
    // Each route keeps the model id the bundle declares for it, so the child a
    // route tool spawns resolves; only the endpoint and the credential name move.
    loopback('zai', ['glm-5.3', 'glm-5.3-code']),
    loopback('anthropic', ['claude-opus-5-5']),
    loopback('openai', ['gpt-6-sol']),
    '',
  ].join('\n')
}

/** The probe overlay that mounts the in-profile E2E probe on the real profile. */
export function probePatch(specPath, patchPath = undefined) {
  return `# E2E-only overlay: run the in-profile assertions. Never part of the bundle.
- insert:
    - id: dsh-main-e2e-probe
      name: '${join(bundleRoot, 'test', 'e2e', 'probe-plugin.mjs')}'
      config:
        spec: '${specPath}'
`
}

export async function setupWorkflowEnvironment() {
  const { version } = assertDshVersion()
  const removed = removeIterationHelpers()
  if (removed.length > 0) process.stderr.write(`[e2e] removed iteration helpers: ${removed.join(', ')}\n`)
  const env = createEnvironment()
  initializeProfile(env)
  const bundles = installBundle(env)
  const git = createGitWorkspace(env)

  // The profile install is what publishes the bundle's skills. A stale install
  // would leave the catalog cases asserting a provider the profile does not
  // have, so the installed copy is checked here rather than asserted later.
  const installedRoot = join(env.home, 'profiles', env.profile, 'node_modules', '@kaikojima', 'dsh-main-policy')
  const installedManifest = JSON.parse(readFileSync(join(installedRoot, 'package.json'), 'utf8'))
  if (!installedManifest.files?.includes('skills')) {
    throw new Error('the installed bundle does not publish its skills directory; reinstall the profile')
  }

  const mock = await startMockProvider()
  const routePatchPath = join(env.root, 'mock-route.yml')
  writeFileSync(routePatchPath, mockRoutePatch(mock.baseURL), 'utf8')

  return {
    version,
    env,
    bundleRoot,
    bundles,
    git,
    installedRoot,
    mock,
    routePatchPath,
    base: git.revParse('HEAD~1'),
    head: git.revParse('HEAD'),
    requirements: 'The change must keep the documented behavior and add no new provider spend.',
    writeSpec(name, spec) {
      const path = join(env.root, `${name}.spec.json`)
      writeFileSync(path, `${JSON.stringify(spec, undefined, 2)}\n`, 'utf8')
      return path
    },
    writePatch(name, contents) {
      const path = join(env.root, `${name}.patch.yml`)
      mkdirSync(env.root, { recursive: true })
      writeFileSync(path, contents, 'utf8')
      return path
    },
    readState() {
      const path = join(env.home, 'dsh-main-policy', 'routing-intents.json')
      try {
        return JSON.parse(readFileSync(path, 'utf8'))
      } catch {
        return undefined
      }
    },
    async cleanup() {
      await mock.close()
      env.cleanup()
    },
  }
}
