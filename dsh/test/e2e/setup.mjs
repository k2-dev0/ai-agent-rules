/**
 * Prepare one end-to-end environment.
 *
 * Everything the real-DSH tests share is created here: a throwaway `DSH_HOME`
 * with the profile installed from this bundle, a throwaway Git workspace with
 * two commits, the deployed skills, the loopback mock provider, and the
 * `--patch` overlays that point the profile at that mock.
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
import { deploySkills } from '../../lib/deploy-skills.js'

/** Skills this distribution publishes to DSH. */
export const DISTRIBUTED_SKILLS = [
  'cowlick', 'dictionary', 'e2e', 'meeting', 'polish',
  'ponytail', 'preflight', 'rebase', 'tdd', 'unwind',
]

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

/** The mock provider overlay, applied with `--patch` and never part of the bundle. */
export function mockRoutePatch(baseURL) {
  return `# E2E-only overlay: a loopback mock provider. Never part of the bundle.
- id: agent-default-model
  config:
    provider: mock
    model: mock-1
- id: llm-pi-ai
  config:
    providers:
      mock:
        apiKeyEnv: ${MOCK_CREDENTIAL_ENV}
        api: openai-completions
        baseURL: ${baseURL}
        models:
          - id: mock-1
            name: Mock 1
            contextWindow: 200000
            maxTokens: 8192
            input: [text]
        retryPolicy:
          mode: normal
          maxRetries: 0
`
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
  const skills = deploySkills({
    sourceRoot: join(repositoryRoot, 'skills'),
    targetRoot: join(env.workdir, '.agents', 'skills'),
  })
  const mock = await startMockProvider()
  const routePatchPath = join(env.root, 'mock-route.yml')
  writeFileSync(routePatchPath, mockRoutePatch(mock.baseURL), 'utf8')

  return {
    version,
    env,
    bundleRoot,
    bundles,
    git,
    skills,
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
