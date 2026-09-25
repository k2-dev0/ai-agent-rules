/**
 * The DSH instruction contract.
 *
 * `AGENTS.dsh.md` is the readable original of the routing instructions; the
 * plugin injects the block between its markers as a system-prompt section. It
 * used to exist as a second copy inside `lib/dsh-instructions.js`, which meant a
 * change to one half silently left the model reading the other.
 *
 * These cases pin the single-source property and the content the rest of the
 * bundle depends on: the injected text must state the ownership rules, and it
 * must exclude the Codex/Claude routing documents by name.
 */

import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import {
  DSH_INSTRUCTIONS,
  INSTRUCTION_MARKERS,
  extractInstructions,
  instructionsFile,
  loadInstructions,
} from '../lib/dsh-instructions.js'
import { apply, inject } from '../index.js'
import { bundleRoot } from './e2e/harness.mjs'

const document = readFileSync(instructionsFile(), 'utf8')

test('the injected instructions are the block the document carries', () => {
  assert.equal(DSH_INSTRUCTIONS, extractInstructions(document))
  assert.equal(DSH_INSTRUCTIONS, loadInstructions())
  assert.equal(document.includes(INSTRUCTION_MARKERS.begin), true)
  assert.equal(document.includes(INSTRUCTION_MARKERS.end), true)
  // The file must exist inside the bundle that ships it, because the plugin
  // resolves it from its own installed location.
  assert.equal(instructionsFile().startsWith(bundleRoot), true)
})

test('the instruction document is the only copy of the text', () => {
  const module = readFileSync(new URL('../lib/dsh-instructions.js', import.meta.url), 'utf8')
  // A literal copy would be a second source of truth; the module must only read.
  assert.equal(module.includes('DSH main execution model:'), false,
    'lib/dsh-instructions.js carries its own copy of the instruction body')
  assert.match(module, /readFileSync/)
})

test('an unusable instruction document fails instead of injecting nothing', () => {
  assert.throws(() => extractInstructions('# no markers here\n'), /BEGIN DSH_INSTRUCTIONS/)
  assert.throws(() => extractInstructions(`${INSTRUCTION_MARKERS.begin}\n${INSTRUCTION_MARKERS.end}`),
    /empty instruction block/)
  // A module URL whose parent directory has no document: the reader must report
  // the deployment fault rather than inject an empty section.
  assert.throws(() => loadInstructions('file:///nonexistent-bundle/lib/dsh-instructions.js'),
    /cannot be read/)
})

test('the injected instructions state the ownership and routing rules', () => {
  const required = [
    'DSH main execution model',
    'no automatic review and no automatic re-review',
    '/external-plan',
    '/opus-plan',
    '/external-code',
    '/review',
    'Legacy routing precedence',
    'not instructions for this session',
  ]
  for (const phrase of required) {
    assert.ok(DSH_INSTRUCTIONS.includes(phrase), `the injected instructions omit "${phrase}"`)
  }
  // The legacy documents are excluded by name, so a reader can tell which files
  // this section overrides rather than having to infer it.
  for (const document of ['skills/WORKFLOW_ROUTING.md', 'skills/DEEPSEEK_WORKFLOW.md', 'skills/MODEL_SELECTION.md']) {
    assert.ok(DSH_INSTRUCTIONS.includes(document), `the precedence rule does not name ${document}`)
  }
})

test('the plugin states the DSH instructions once and pins the service list', () => {
  assert.equal(typeof apply, 'function')
  assert.deepEqual([...inject].sort(), ['agents', 'commands', 'skills', 'systemPrompt', 'tools'])
  const index = readFileSync(new URL('../index.js', import.meta.url), 'utf8')
  // The plugin must inject this module's export rather than a literal of its own.
  assert.match(index, /import \{ DSH_INSTRUCTIONS \} from '\.\/lib\/dsh-instructions\.js'/)
  assert.match(index, /name: 'dsh-main-execution-model', text: DSH_INSTRUCTIONS/)
})
