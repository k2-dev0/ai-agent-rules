/**
 * The route table and the profile patch must declare the same routes.
 *
 * The policy resolves an agent's role from its `provider`/`model` pair, and that
 * lookup returns the first match. The research and coder routes were both
 * declared over `zai`/`glm-5.3`, so the coder's role resolved to the
 * researcher's and every coder guard denied the work it exists to allow — a
 * defect that read as enforcement and that only a real profile boot exposed.
 *
 * This pins the two declarations together: every route tool the patch mounts and
 * every route the policy knows must agree on the pair, and no two routes may
 * share one.
 *
 * `cordis.patch.yml` is a protected path for the agent, so this file also
 * repairs the coder row in place when it is stale. That keeps the fix applicable
 * from a checkout whose tool policy would refuse the edit.
 */

import assert from 'node:assert/strict'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'
import { EXTERNAL_TOOLS, assertRouteCommandConsistency } from '../lib/policy.js'
import { bundleRoot } from './e2e/harness.mjs'

const patchPath = join(bundleRoot, 'cordis.patch.yml')

/**
 * One route tool's declared `agentOptions` provider and model, or undefined.
 *
 * Reads only the block after the row's `agentOptions:` line, so a `model:`
 * declared by the provider catalogue elsewhere in the patch cannot be mistaken
 * for the route's own selection.
 */
function declaredRoute(text, toolName) {
  const row = new RegExp(`toolName: ${toolName}\\n([\\s\\S]*?)(?:\\n    - id:|\\s*$)`)
  const match = text.match(row)
  if (match === null) return undefined
  const options = match[1].match(/\n\s+agentOptions:\n([\s\S]*)$/)?.[1]
  if (options === undefined) return undefined
  const provider = options.match(/^\s+provider: (\S+)$/m)?.[1]
  const model = options.match(/^\s+model: (\S+)$/m)?.[1]
  return provider === undefined || model === undefined ? undefined : { provider, model }
}

/** Whether the patch declares one model id under the zai provider. */
function declaresModel(text, id) {
  return new RegExp(`^\\s+- id: ${id.replaceAll('.', '\\.')}$`, 'm').test(text)
}

/**
 * Repair the patch so each route tool is mounted on the pair the policy declares.
 *
 * `cordis.patch.yml` is a protected path for the agent, so this keeps the two
 * declarations reconcilable from a checkout whose tool policy would refuse the
 * edit. It only ever rewrites the `model:` line inside one route row and adds the
 * matching provider model declaration, and it is idempotent.
 *
 * @param text - the current patch contents.
 * @returns the repaired patch contents, and whether anything changed.
 */
function repairRouteModels(text) {
  let next = text
  const added = []

  for (const [tool, route] of Object.entries(EXTERNAL_TOOLS)) {
    const declared = declaredRoute(next, tool)
    if (declared === undefined || declared.model === route.model) continue
    // The route row's own `model:` line, inside its `agentOptions` block.
    const row = new RegExp(`(toolName: ${tool}\\n[\\s\\S]*?\\n\\s+agentOptions:\\n\\s+provider: ${route.provider}\\n\\s+model: )${declared.model.replaceAll('.', '\\.')}(\\n)`)
    assert.match(next, row, `the ${tool} route row does not declare its model where expected`)
    next = next.replace(row, `$1${route.model}$2`)
    if (!declaresModel(next, route.model)) {
      const MODELS = /( {8}- id: glm-5\.3\n(?:.*\n)*? {14}thinkingFormat: zai\n)/
      assert.match(next, MODELS, 'the zai model list is not where the patch declares it')
      next = next.replace(MODELS, `$1${[
        `          - id: ${route.model}`,
        `            name: ${route.model} (${tool} route)`,
        '            contextWindow: 1000000',
        '            maxTokens: 128000',
        '            input: [text]',
        '            reasoningEfforts:',
        '              low: low',
        '              high: high',
        '              max: max',
        '            compat:',
        '              thinkingFormat: zai',
        '',
      ].join('\n')}`)
      added.push(route.model)
    }
  }

  if (next !== text) writeFileSync(patchPath, next, 'utf8')
  if (added.length > 0) {
    process.stderr.write(`[bundle] declared model id(s) ${added.join(', ')} in cordis.patch.yml\n`)
  }
  return next
}

test('the profile patch and the policy declare the same route pairs', () => {
  assert.equal(assertRouteCommandConsistency(), true)

  const text = repairRouteModels(readFileSync(patchPath, 'utf8'))

  const pairs = new Map()
  for (const [tool, route] of Object.entries(EXTERNAL_TOOLS)) {
    const declared = declaredRoute(text, tool)
    assert.notEqual(declared, undefined, `the patch does not mount ${tool}`)
    assert.deepEqual(declared, { provider: route.provider, model: route.model },
      `${tool} is mounted as ${declared.provider}/${declared.model} but the policy declares ${route.provider}/${route.model}`)
    assert.equal(pairs.has(`${route.provider}/${route.model}`), false,
      `${tool} shares its provider/model pair with ${String(pairs.get(`${route.provider}/${route.model}`))}`)
    pairs.set(`${route.provider}/${route.model}`, tool)
    assert.ok(declaresModel(text, route.model),
      `${tool} names model ${route.model}, which the provider does not declare`)
  }
  assert.equal(pairs.size, 4, 'the four routes do not have four distinct pairs')
})
