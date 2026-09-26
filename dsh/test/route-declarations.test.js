/**
 * The route declaration contract between the policy and the profile patch.
 *
 * A route's model entry is the only place that describes a model the installed
 * pi-ai catalog does not ship. `claude-opus-5-5` is exactly that: pi-ai 0.85.1
 * knows `claude-opus-5` and stops there, so nothing supplies the compat the
 * model needs, and pi-ai falls back to the budget-based thinking request an
 * adaptive-only model rejects — before it produces a single token. The failure
 * reached the caller as `subagent run failed` with zero token usage, which names
 * neither the route nor the missing field.
 *
 * Two halves keep that from recurring:
 *
 * 1. the patch must declare the compat its protocol requires, pinned here, and
 * 2. activation refuses a bundle whose declaration drifted —
 *    {@link assertRouteDeclarations} is called from `index.js`.
 *
 * The requirement is per protocol rather than per model: an `anthropic-messages`
 * route declares it even when it names a catalog model, because the declaration
 * is what the materialized model carries when the catalog describes nothing.
 */

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'
import { EXTERNAL_TOOLS, ROUTE_MODEL_REQUIREMENTS, assertRouteDeclarations } from '../lib/policy.js'
import { bundleRoot } from './e2e/harness.mjs'

const patch = readFileSync(join(bundleRoot, 'cordis.patch.yml'), 'utf8')

/** The one route these cases judge, so an absent sibling cannot mask a verdict. */
const OPUS_ONLY = { external_opus_design: EXTERNAL_TOOLS.external_opus_design }

/** A patch naming the anthropic route, with whatever the case adds to its model. */
function anthropicPatch({ api = 'anthropic-messages', modelLines = [] } = {}) {
  return [
    '- id: llm-pi-ai',
    '  config:',
    '    providers:',
    '      anthropic:',
    `        api: ${api}`,
    '        models:',
    '          - id: claude-opus-5-5',
    '            contextWindow: 1000000',
    ...modelLines,
    '',
  ].join('\n')
}

/** The shipped patch with the anthropic model's compat block removed. */
function withoutAdaptiveCompat(text) {
  const stripped = text.replace(/( {10}- id: claude-opus-5-5\n(?:.*\n)*?)(?: {12}compat:\n(?: {14}.*\n)+)/, '$1')
  assert.notEqual(stripped, text, 'the fixture did not find the anthropic model compat block')
  return stripped
}

test('every shipped route model declares the compat its protocol requires', () => {
  assert.equal(assertRouteDeclarations(patch), true)
})

test('the anthropic model entry forces adaptive thinking for the model pi-ai cannot describe', () => {
  assert.match(
    patch,
    /^ {10}- id: claude-opus-5-5\n(?: {12}[^\n]*\n)*? {12}compat:\n(?: {14}[^\n]*\n)*? {14}forceAdaptiveThinking: true$/m,
    'the anthropic model entry does not force adaptive thinking; pi-ai then sends the budget-based thinking request that model rejects',
  )
})

test('a route model missing its required compat is refused with the route, protocol, and field named', () => {
  assert.throws(
    () => assertRouteDeclarations(withoutAdaptiveCompat(patch), OPUS_ONLY),
    error => error.message.includes('external_opus_design')
      && error.message.includes('anthropic-messages')
      && error.message.includes('forceAdaptiveThinking'),
    'the refusal does not name the route, its protocol, and the missing field',
  )
  assert.throws(
    () => assertRouteDeclarations(anthropicPatch(), OPUS_ONLY),
    /forceAdaptiveThinking/,
    'a model entry with no compat block passed the check',
  )
})

test('a compat block that names another field does not satisfy the requirement', () => {
  const text = anthropicPatch({
    modelLines: [
      '            compat:',
      '              supportsTemperature: false',
    ],
  })
  assert.throws(() => assertRouteDeclarations(text, OPUS_ONLY), /forceAdaptiveThinking/)
})

test('a model entry that names its own protocol is judged by that protocol', () => {
  const text = anthropicPatch({
    modelLines: [
      '            api: openai-responses',
      '            compat:',
      '              forceAdaptiveThinking: true',
    ],
  })
  // The switch is offered on `anthropic-messages` alone, so a model that speaks
  // another protocol is not judged by it.
  assert.equal(assertRouteDeclarations(text, OPUS_ONLY), true)
})

test('a patch that names none of the routes is refused rather than read as compliant', () => {
  for (const text of ['', '# no rows here\n', '- id: llm-pi-ai\n  config:\n    providers: {}\n']) {
    assert.throws(() => assertRouteDeclarations(text), /external_opus_design/,
      'an empty declaration passed the route check')
  }
})

test('the refusal reports every route it could not verify', () => {
  assert.throws(() => assertRouteDeclarations(''), error => {
    const details = error.message.split('\n').filter(line => line.startsWith('- '))
    assert.equal(details.length, Object.keys(EXTERNAL_TOOLS).length,
      `the refusal listed ${details.length} of ${Object.keys(EXTERNAL_TOOLS).length} routes`)
    return true
  })
})

test('the required compat is declared per protocol, not per model', () => {
  assert.deepEqual(ROUTE_MODEL_REQUIREMENTS['anthropic-messages'], ['forceAdaptiveThinking'])
  assert.equal(Object.keys(ROUTE_MODEL_REQUIREMENTS).includes('openai-completions'), false,
    'a protocol pi-ai serves without catalog compat must not require one')
})
