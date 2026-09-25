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
    source: 'command',
    delegationDepth: 0,
    ...overrides,
    // The registered command always determines the route tool, exactly as the
    // plugin's dispatch does; callers override it only to test mismatches.
    tool: overrides.tool ?? routeToolForCommand(command),
  })
}

/** Open one intent and deliver it into `turn`, which is what authorizes a route. */
function openDelivered(store, turn, overrides = {}) {
  const opened = open(store, overrides)
  assert.equal(opened.ok, true, `open failed: ${opened.reason}`)
  const bound = store.bindDelivery(opened.intent.sessionId, opened.intent.id, turn)
  assert.equal(bound.ok, true, `bindDelivery failed: ${bound.reason}`)
  store.noteDelivered(opened.intent.sessionId, turn, opened.intent.id)
  return opened
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

test('an admitted command needs no turn, and stores no task text', () => {
  // A registered command is dispatched by the command registry, which does not
  // open a turn. Demanding one here would refuse every command a human types.
  const store = new RoutingIntentStore()
  const opened = open(store)
  assert.equal(opened.ok, true, `open failed: ${opened.reason}`)
  assert.equal(opened.intent.status, 'open')
  assert.equal(opened.intent.deliveredTurn, null)
  // Task text is never stored: policy state must not copy user content.
  assert.equal('taskText' in opened.intent, false)
  assert.equal(JSON.stringify(store.toState()).includes('investigate the cache layer'), false)
})

test('the intent is bound to the turn that received its task message', () => {
  const store = new RoutingIntentStore()
  const { intent } = open(store)
  // Before delivery there is no turn to authorize, so the route is refused.
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 1,
    tool: 'external_research_design',
    openIntent: intent,
  }).allowed, false)

  assert.equal(store.bindDelivery('session-a', intent.id, 0).ok, false)
  assert.equal(store.bindDelivery('session-a', intent.id, undefined).ok, false)
  const bound = store.bindDelivery('session-a', intent.id, 3)
  assert.equal(bound.ok, true, `bindDelivery failed: ${bound.reason}`)
  assert.equal(store.get('session-a', intent.id).deliveredTurn, 3)
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 3,
    tool: 'external_research_design',
    openIntent: store.openIntent('session-a'),
  }).allowed, true)
})

test('one intent cannot be delivered into two turns', () => {
  const store = new RoutingIntentStore()
  const { intent } = open(store)
  assert.equal(store.bindDelivery('session-a', intent.id, 1).ok, true)
  const again = store.bindDelivery('session-a', intent.id, 2)
  assert.equal(again.ok, false, 'a second delivery re-bound the same intent')
  assert.match(again.reason, /配送済み/)
  assert.equal(store.get('session-a', intent.id).deliveredTurn, 1)
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
    openIntent: { tool: 'external_research_design', sessionId: 'child', deliveredTurn: 1 },
    delegationDepth: 1,
  }).allowed, false)
})

test('the route tool runs once against its own intent only', () => {
  const store = new RoutingIntentStore()
  const { intent } = openDelivered(store, 1)
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
  }).allowed, false, 'the intent authorized a turn it never received')
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

test('the mutually exclusive plan commands conflict in one task in both orders', () => {
  // Each command line is its own turn, so the conflict is decided across turns
  // by the earlier route being admitted and not yet settled.
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

test('a settled plan route no longer blocks the other plan command', () => {
  const store = new RoutingIntentStore()
  const first = openDelivered(store, 1, { command: 'external-plan' })
  const consumed = store.consume('session-a', first.intent.id)
  assert.equal(consumed.ok, true)
  // A turn end settles the route, which is what frees the exclusive slot.
  store.closeTurn('session-a', 1, 'turn-end:completed')
  const second = open(store, { command: 'opus-plan' })
  assert.equal(second.ok, true, `a finished plan route still conflicted: ${second.reason}`)
})

test('an undelivered route still blocks the exclusive command', () => {
  const store = new RoutingIntentStore()
  const admitted = open(store, { command: 'external-plan' })
  assert.equal(admitted.ok, true)
  const conflict = open(store, { command: 'opus-plan' })
  assert.equal(conflict.ok, false, 'an admitted but undelivered plan route did not conflict')
})

test('the same command twice supersedes rather than duplicating the route', () => {
  const store = new RoutingIntentStore()
  const first = open(store)
  const second = open(store)
  assert.equal(second.ok, true)
  assert.equal(store.get('session-a', first.intent.id).status, 'closed')
  assert.equal(store.get('session-a', first.intent.id).closedReason, 'superseded-by-command')
  assert.equal(store.openIntent('session-a').id, second.intent.id)
  assert.equal(store.size, 2)
})

test('turn end settles the intent that turn received and forbids reuse', () => {
  for (const [reason, expected] of [
    ['turn-end:completed', 'turn-end:completed'],
    ['cancelled:user', 'cancelled:user'],
  ]) {
    const store = new RoutingIntentStore()
    const { intent } = openDelivered(store, 1)
    assert.equal(store.deliveredIntentForTurn('session-a', 1).id, intent.id)
    const closed = store.closeTurn('session-a', 1, reason)
    assert.equal(closed.length, 1)
    assert.equal(closed[0].id, intent.id)
    assert.equal(store.get('session-a', intent.id).closedReason, expected)
    assert.equal(store.deliveredIntentForTurn('session-a', 1), undefined)
    assert.equal(authorizeRouteTool({
      sessionId: 'session-a',
      turn: 1,
      tool: 'external_research_design',
      openIntent: store.openIntent('session-a'),
    }).allowed, false)
  }
})

test('a turn end does not cancel a route whose task text has not arrived yet', () => {
  // The Web composer submits a command in its own turn and the task text is the
  // next turn, so settling the undelivered intent here would silently drop it.
  const store = new RoutingIntentStore()
  const { intent } = open(store)
  assert.deepEqual(store.closeTurn('session-a', 1, 'turn-end:completed'), [])
  assert.equal(store.openIntent('session-a').id, intent.id)
  assert.equal(store.bindDelivery('session-a', intent.id, 2).ok, true)
  assert.equal(store.get('session-a', intent.id).status, 'open')
})

test('disposal closes every open intent', () => {
  const store = new RoutingIntentStore()
  const { intent } = open(store)
  assert.equal(store.closeSession('session-a', 'agent-disposed').length, 1)
  assert.equal(store.get('session-a', intent.id).closedReason, 'agent-disposed')
  assert.equal(store.openIntent('session-a'), undefined)
  assert.equal(store.deliveredIntentForTurn('session-a', 1), undefined)
})

test('a later turn does not inherit an earlier intent', () => {
  const store = new RoutingIntentStore()
  openDelivered(store, 1)
  store.closeTurn('session-a', 1, 'turn-end:completed')
  const second = openDelivered(store, 2, { command: 'external-code' })
  assert.equal(second.intent.deliveredTurn, 2)
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 1,
    tool: 'external_code',
    openIntent: store.openIntent('session-a'),
  }).allowed, false, 'an intent delivered in turn 2 authorized turn 1')
})

test('restart never resumes a persisted intent, and keeps the consumed fact', () => {
  const store = new RoutingIntentStore()
  const first = openDelivered(store, 1)
  store.consume('session-a', first.intent.id)
  // The snapshot that survives a restart records the one-shot consumption.
  const live = JSON.parse(JSON.stringify(store.toState()))
  assert.equal(live.intents.find(intent => intent.id === first.intent.id).status, 'consumed')

  // The consumed route settles when its turn ends; until then it still owns its
  // exclusive slot, which is why the review is admitted only after that turn ends.
  store.closeTurn('session-a', 1, 'turn-end:completed')
  const other = open(store, { command: 'review' })
  assert.equal(other.ok, true, `the review route was refused: ${other.reason}`)

  const restored = RoutingIntentStore.fromState(JSON.parse(JSON.stringify(store.toState())))
  assert.equal(restored.size, 2)
  assert.equal(restored.get('session-a', first.intent.id).status, 'closed')
  assert.equal(restored.get('session-a', first.intent.id).deliveredTurn, 1)
  assert.equal(restored.get('session-a', other.intent.id).status, 'open')

  // The plugin closes every restored open intent before serving traffic, so a
  // persisted intent is never resumed as authorization for a fresh turn.
  for (const record of restored.toState().intents) {
    if (record.status === 'open') restored.closeSession(record.sessionId, 'restart')
  }
  assert.equal(restored.openIntent('session-a'), undefined)
  assert.equal(restored.get('session-a', other.intent.id).closedReason, 'restart')
  assert.equal(restored.hasUnsettledIntent('session-a', ['review']), false,
    'a restored-then-closed intent still counts as unsettled')
})

test('malformed or unsupported persisted state fails closed', () => {
  assert.throws(() => RoutingIntentStore.fromState('nope'), /must be one JSON object/)
  assert.throws(() => RoutingIntentStore.fromState({ version: 99, intents: [] }), /unsupported version/)
  assert.throws(() => RoutingIntentStore.fromState({ version: ROUTING_INTENT_STATE_VERSION }), /intents array/)
  assert.throws(() => RoutingIntentStore.fromState({
    version: ROUTING_INTENT_STATE_VERSION,
    intents: [{ id: 'x', command: 'review', tool: 'external_code', sessionId: 's', status: 'open' }],
  }), /malformed intent record/)
  assert.throws(() => RoutingIntentStore.fromState({
    version: ROUTING_INTENT_STATE_VERSION,
    intents: [{ id: 'x', command: 'review', tool: 'review_change', sessionId: '', status: 'open' }],
  }), /malformed intent record/)
  assert.equal(RoutingIntentStore.fromState(undefined).size, 0)
})

test('the delivered intent context names the command, tool, id, and task', () => {
  const plan = openDelivered(new RoutingIntentStore(), 1)
  const text = intentContextText(plan.intent, '要件を整理して')
  assert.match(text, /^<dsh_routing_intent>/)
  assert.match(text, /command: \/external-plan/)
  assert.match(text, /tool: external_research_design/)
  assert.match(text, new RegExp(`intent_id: ${plan.intent.id}`))
  assert.match(text, /要件を整理して/)
  assert.match(text, /<\/dsh_routing_intent>$/)

  const review = openDelivered(new RoutingIntentStore(), 1, { command: 'review' })
  assert.match(intentContextText(review.intent, ''), /no task text was supplied/)
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
