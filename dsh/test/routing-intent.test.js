import assert from 'node:assert/strict'
import test from 'node:test'
import {
  COMMAND_ROUTES,
  MUTUALLY_EXCLUSIVE_COMMANDS,
  ROUTE_TOOLS,
  ROUTING_INTENT_STATE_VERSION,
  RoutingIntentStore,
  authorizeRouteTool,
  commandForRouteTool,
  intentContextText,
  registeredCommandNames,
  routeToolForCommand,
} from '../lib/routing-intent.js'
import { EXTERNAL_TOOLS, assertRouteCommandConsistency, commandTokens } from '../lib/policy.js'

function open(store, overrides = {}) {
  const command = overrides.command ?? 'external-plan'
  return store.open({
    command,
    sessionId: 'session-a',
    turn: 1,
    taskText: 'investigate the cache layer',
    source: 'command',
    delegationDepth: 0,
    ...overrides,
    // The registered command always determines the route tool, exactly as the
    // plugin's dispatch does; callers override it only to test mismatches.
    tool: overrides.tool ?? routeToolForCommand(command),
  })
}

test('the command table and the route table describe the same four routes', () => {
  assert.equal(assertRouteCommandConsistency(), true)
  assert.deepEqual(registeredCommandNames(), ['external-plan', 'opus-plan', 'external-code', 'review'])
  assert.deepEqual(Object.values(COMMAND_ROUTES).sort(), [...ROUTE_TOOLS].sort())
  for (const [command, tool] of Object.entries(COMMAND_ROUTES)) {
    assert.equal(routeToolForCommand(command), tool)
    assert.equal(commandForRouteTool(tool), command)
    assert.equal(EXTERNAL_TOOLS[tool].command, command)
  }
})

test('an unknown command never resolves to a route tool', () => {
  for (const name of ['plan', 'external_plan', 'External-Plan', 'external-plan-extra', 'review2', '']) {
    assert.equal(routeToolForCommand(name), undefined)
  }
})

test('only a direct command dispatch can open a routing intent', () => {
  const store = new RoutingIntentStore()
  for (const source of ['user-message', 'repository', 'skill', 'tool-result', 'model', undefined]) {
    const result = open(store, { source })
    assert.equal(result.ok, false, `source ${String(source)} must not open an intent`)
    assert.match(result.reason, /direct user command dispatch/)
  }
  assert.equal(store.size, 0)
})

test('an unregistered command name never opens an intent', () => {
  const store = new RoutingIntentStore()
  for (const command of ['plan', 'external-plan-x', 'EXTERNAL-PLAN', 'subagent', '', undefined]) {
    const result = open(store, { command })
    assert.equal(result.ok, false, `command ${JSON.stringify(command)} must not open an intent (got ${JSON.stringify(result)})`)
    assert.match(result.reason, /not a registered routing command/)
  }
  assert.equal(store.size, 0)
})

test('a command handler must not register a mislabelled route tool', () => {
  const store = new RoutingIntentStore()
  // The dispatch always supplies the tool for its own command name; a mismatch
  // is a wiring bug, and the store refuses it instead of trusting the caller.
  const mismatched = open(store, { command: 'review', tool: 'external_code' })
  assert.equal(mismatched.ok, false)
  assert.match(mismatched.reason, /is not the route tool registered for \/review/)
  assert.equal(store.size, 0)
})

test('an intent is bound to the turn that admitted the command', () => {
  const store = new RoutingIntentStore()
  assert.equal(open(store, { turn: 0 }).ok, false)
  assert.equal(open(store, { turn: undefined }).ok, false)
  assert.equal(open(store, { turn: '1' }).ok, false)
  const intent = open(store, { turn: 3 })
  assert.equal(intent.ok, true)
  assert.equal(intent.intent.turn, 3)
  assert.equal(intent.intent.status, 'open')
  // Task text is never stored: policy state must not copy user content.
  assert.equal('taskText' in intent.intent, false)
  assert.equal(JSON.stringify(store.toState()).includes('investigate the cache layer'), false)
})

test('a nested agent cannot open or use a routing intent', () => {
  const store = new RoutingIntentStore()
  const nested = open(store, { delegationDepth: 1 })
  assert.equal(nested.ok, false)
  assert.match(nested.reason, /外部role/)
  assert.equal(authorizeRouteTool({
    sessionId: 'child',
    turn: 1,
    tool: 'external_research_design',
    openIntent: { tool: 'external_research_design', sessionId: 'child', turn: 1 },
    delegationDepth: 1,
  }).allowed, false)
})

test('the route tool runs once against its own intent only', () => {
  const store = new RoutingIntentStore()
  const { intent } = open(store)
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 1,
    tool: 'external_code',
    openIntent: intent,
  }).allowed, false)
  assert.equal(authorizeRouteTool({
    sessionId: 'session-b',
    turn: 1,
    tool: 'external_research_design',
    openIntent: intent,
  }).allowed, false)
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 2,
    tool: 'external_research_design',
    openIntent: intent,
  }).allowed, false)
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 1,
    tool: 'external_research_design',
    openIntent: intent,
  }).allowed, true)

  assert.equal(store.consume('session-a', intent.id).ok, true)
  const reuse = authorizeRouteTool({
    sessionId: 'session-a',
    turn: 1,
    tool: 'external_research_design',
    openIntent: store.openIntent('session-a'),
  })
  assert.equal(reuse.allowed, false)
  assert.equal(store.consume('session-a', intent.id).ok, false)
  assert.match(store.consume('session-a', intent.id).reason, /使用済み|終了済み/)
})

test('no intent at all means no external route, not a fallback', () => {
  const store = new RoutingIntentStore()
  const decision = authorizeRouteTool({
    sessionId: 'session-a',
    turn: 1,
    tool: 'review_change',
    openIntent: store.openIntent('session-a'),
    delegationDepth: 0,
  })
  assert.equal(decision.allowed, false)
  assert.match(decision.reason, /\/review/)
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 1,
    tool: 'subagent',
    openIntent: undefined,
  }).allowed, false)
})

test('the mutually exclusive plan commands conflict in one turn in both orders', () => {
  for (const [first, second] of [['external-plan', 'opus-plan'], ['opus-plan', 'external-plan']]) {
    const store = new RoutingIntentStore()
    const opened = open(store, { command: first })
    assert.equal(opened.ok, true)
    const conflict = open(store, { command: second })
    assert.equal(conflict.ok, false, `${second} after ${first} must conflict`)
    assert.match(conflict.reason, /併用できません/)
  }
  assert.deepEqual([...MUTUALLY_EXCLUSIVE_COMMANDS], ['external-plan', 'opus-plan'])
})

test('the same command twice in one turn supersedes rather than duplicating the route', () => {
  const store = new RoutingIntentStore()
  const first = open(store)
  const second = open(store, { taskText: 'revised task' })
  assert.equal(second.ok, true)
  assert.equal(store.get('session-a', first.intent.id).status, 'closed')
  assert.equal(store.get('session-a', first.intent.id).closedReason, 'superseded-by-command')
  assert.equal(store.openIntent('session-a').id, second.intent.id)
  assert.equal(store.size, 2)
})

test('turn end, cancellation, and disposal close the intent and forbid reuse', () => {
  for (const [reason, expected] of [
    ['turn-end:completed', 'turn-end:completed'],
    ['cancelled:user', 'cancelled:user'],
  ]) {
    const store = new RoutingIntentStore()
    const { intent } = open(store)
    const closed = store.closeTurn('session-a', 1, reason)
    assert.equal(closed.length, 1)
    assert.equal(closed[0].id, intent.id)
    assert.equal(store.get('session-a', intent.id).closedReason, expected)
    assert.equal(authorizeRouteTool({
      sessionId: 'session-a',
      turn: 1,
      tool: 'external_research_design',
      openIntent: store.openIntent('session-a'),
    }).allowed, false)
  }

  const store = new RoutingIntentStore()
  const { intent } = open(store)
  assert.equal(store.closeSession('session-a', 'agent-disposed').length, 1)
  assert.equal(store.get('session-a', intent.id).closedReason, 'agent-disposed')
  assert.equal(store.openIntent('session-a'), undefined)
})

test('a later turn does not inherit an earlier intent', () => {
  const store = new RoutingIntentStore()
  open(store, { turn: 1 })
  store.closeTurn('session-a', 1, 'turn-end:completed')
  const second = open(store, { turn: 2, command: 'external-code' })
  assert.equal(second.ok, true)
  assert.equal(store.openIntent('session-a').turn, 2)
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 1,
    tool: 'external_code',
    openIntent: store.openIntent('session-a'),
  }).allowed, false)
})

test('restart never resumes a persisted open intent, but keeps consumed facts', () => {
  const store = new RoutingIntentStore()
  const { intent } = open(store)
  store.consume('session-a', intent.id)
  const other = open(store, { turn: 2, command: 'review' })
  assert.equal(other.ok, true)

  const restored = RoutingIntentStore.fromState(JSON.parse(JSON.stringify(store.toState())))
  assert.equal(restored.size, 2)
  assert.equal(restored.get('session-a', intent.id).status, 'consumed')
  assert.equal(restored.get('session-a', other.intent.id).status, 'open')

  // The plugin closes every restored open intent before serving traffic.
  for (const record of restored.toState().intents) {
    if (record.status === 'open') restored.closeSession(record.sessionId, 'restart')
  }
  assert.equal(restored.openIntent('session-a'), undefined)
  assert.equal(restored.get('session-a', other.intent.id).closedReason, 'restart')
  assert.equal(restored.get('session-a', intent.id).status, 'consumed')
})

test('malformed or unsupported persisted state fails closed', () => {
  assert.throws(() => RoutingIntentStore.fromState('nope'), /must be one JSON object/)
  assert.throws(() => RoutingIntentStore.fromState({ version: 99, intents: [] }), /unsupported version/)
  assert.throws(() => RoutingIntentStore.fromState({ version: ROUTING_INTENT_STATE_VERSION }), /intents array/)
  assert.throws(() => RoutingIntentStore.fromState({
    version: ROUTING_INTENT_STATE_VERSION,
    intents: [{ id: 'x', command: 'review', tool: 'external_code', sessionId: 's', turn: 1, status: 'open' }],
  }), /malformed intent record/)
  assert.throws(() => RoutingIntentStore.fromState({
    version: ROUTING_INTENT_STATE_VERSION,
    intents: [{ id: 'x', command: 'review', tool: 'review_change', sessionId: 's', turn: -1, status: 'open' }],
  }), /malformed intent record/)
  assert.equal(RoutingIntentStore.fromState(undefined).size, 0)
})

test('the delivered intent context names the command, tool, id, and task', () => {
  const store = new RoutingIntentStore()
  const { intent } = open(store, { taskText: '要件を整理して' })
  const text = intentContextText(intent, '要件を整理して')
  assert.match(text, /^<dsh_routing_intent>/)
  assert.match(text, /command: \/external-plan/)
  assert.match(text, /tool: external_research_design/)
  assert.match(text, new RegExp(`intent_id: ${intent.id}`))
  assert.match(text, /要件を整理して/)
  assert.match(text, /<\/dsh_routing_intent>$/)

  const empty = open(store, { command: 'review', turn: 2, taskText: '   ' })
  assert.equal(empty.ok, true)
  assert.match(intentContextText(empty.intent, ''), /no task text was supplied/)
})

test('command tokens are exact, whitespace-bounded slash tokens only', () => {
  assert.deepEqual(commandTokens('/review'), ['review'])
  assert.deepEqual(commandTokens('  /external-plan please'), ['external-plan'])
  assert.deepEqual(commandTokens('/external-plan /opus-plan'), ['external-plan', 'opus-plan'])
  assert.deepEqual(commandTokens('docs say to run /review here'), ['review'])
  assert.deepEqual(commandTokens('/reviewer'), [])
  assert.deepEqual(commandTokens('https://example.com/review'), [])
  assert.deepEqual(commandTokens('GLM-5.3で調査と概要設計をして'), [])
  assert.deepEqual(commandTokens('$review'), [])
})
