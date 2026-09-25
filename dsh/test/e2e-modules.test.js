/**
 * The end-to-end harness contract.
 *
 * `npm test` covers the bundle's own modules, but the in-profile probe and the
 * driver are loaded by a booted DSH process, so a syntax or wiring fault there
 * only shows up as "the probe produced no results" three minutes into a real
 * boot. Importing them here turns that into an immediate, named failure.
 *
 * `apply` is deliberately not called: it writes a report for the process that
 * booted it, and this file only checks that the module can be loaded and that
 * the surface the patch mount relies on is present.
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import {
  DESIGN_HANDOFF,
  DESIGN_HANDOFF_HEADINGS,
  DISTRIBUTED_SKILLS,
  mockRoutePatch,
  probePatch,
  setupWorkflowEnvironment,
} from './e2e/setup.mjs'
import * as probe from './e2e/probe-plugin.mjs'
import {
  bundleRoot,
  createEnvironment,
  createGitWorkspace,
  initializeProfile,
  installBundle,
  MOCK_CREDENTIAL,
  MOCK_CREDENTIAL_ENV,
  removeIterationHelpers,
  resolveDshBin,
  runDsh,
  stageBundleCopy,
  webBootArgs,
} from './e2e/harness.mjs'

test('the probe plugin loads and exports the surface the patch mount needs', () => {
  // The patch inserts this module by path and Cordis reads these three names.
  assert.equal(probe.name, 'dsh-main-e2e-probe')
  assert.equal(typeof probe.apply, 'function')
  assert.ok(Array.isArray(probe.inject), 'the probe declares no injected services')
  for (const service of ['agents', 'commands', 'skills', 'systemPrompt', 'tools']) {
    assert.ok(probe.inject.includes(service), `the probe does not inject ${service}`)
  }
})

test('the harness exports every helper the setup and driver call', () => {
  for (const [name, value] of Object.entries({
    bundleRoot,
    createEnvironment,
    createGitWorkspace,
    initializeProfile,
    installBundle,
    removeIterationHelpers,
    resolveDshBin,
    runDsh,
    stageBundleCopy,
    webBootArgs,
  })) {
    assert.notEqual(value, undefined, `the harness does not export ${name}`)
  }
  assert.equal(typeof setupWorkflowEnvironment, 'function')
  assert.equal(typeof mockRoutePatch, 'function')
  assert.equal(typeof probePatch, 'function')
  assert.equal(MOCK_CREDENTIAL_ENV, 'DSH_E2E_MOCK_API_KEY')
  assert.ok(MOCK_CREDENTIAL.length > 0)
})

test('the mock route overlay never references a real provider credential', () => {
  const patch = mockRoutePatch('http://127.0.0.1:1/v1')
  assert.match(patch, new RegExp(`apiKeyEnv: ${MOCK_CREDENTIAL_ENV}`))
  for (const real of ['ZAI_API_KEY', 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY', 'DEEPSEEK_API_KEY']) {
    assert.equal(patch.includes(real), false, `the mock overlay references ${real}`)
  }
  assert.match(patch, /provider: mock/)
})

test('the probe overlay mounts the probe by absolute path and never by package name', () => {
  const patch = probePatch('/tmp/spec.json')
  assert.match(patch, /id: dsh-main-e2e-probe/)
  assert.ok(patch.includes(`${bundleRoot}/test/e2e/probe-plugin.mjs`))
  assert.match(patch, /spec: '\/tmp\/spec\.json'/)
})

test('the Design Handoff contract is ordered and complete', () => {
  assert.equal(DESIGN_HANDOFF_HEADINGS[0], '# Design Handoff')
  for (const heading of DESIGN_HANDOFF_HEADINGS) {
    assert.ok(DESIGN_HANDOFF.includes(heading), `the sample handoff omits ${heading}`)
  }
  // The probe's routes must produce these in order, so the sample is the shape
  // the policy validates rather than a free-form document.
  let position = -1
  for (const heading of DESIGN_HANDOFF_HEADINGS) {
    const next = DESIGN_HANDOFF.indexOf(heading, position + 1)
    assert.ok(next > position, `${heading} is out of order in the sample handoff`)
    position = next
  }
})

test('the distributed skill list comes from the bundle provider', () => {
  assert.ok(DISTRIBUTED_SKILLS.length > 0, 'the bundle publishes no skill')
  assert.equal(DISTRIBUTED_SKILLS.includes('bootstrap'), false, 'the legacy step must not be published')
  assert.deepEqual([...DISTRIBUTED_SKILLS].sort(), [...DISTRIBUTED_SKILLS], 'the skill list is not sorted')
})
