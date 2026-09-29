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
  intentCallCount,
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

test('a route tool runs repeatably for its session, whatever turn it is', () => {
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
  // A later turn is the route's own session asking again, which is exactly the
  // case the turn boundary used to refuse.
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 2,
    tool: 'external_research_design',
    openIntent: intent,
  }).allowed, true, 'the authorization was refused in a later turn')
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 1,
    tool: 'external_research_design',
    openIntent: intent,
  }).allowed, true)

  // Authorization is repeatable: a second call in the same turn is allowed, and
  // the intent stays open for as many runs as the task needs.
  assert.equal(store.authorize('session-a', intent.id).ok, true)
  assert.equal(store.get('session-a', intent.id).status, 'open')
  assert.equal(store.openIntent('session-a').id, intent.id)
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 1,
    tool: 'external_research_design',
    openIntent: store.openIntent('session-a'),
  }).allowed, true, 'a second run in the same turn was refused')

  const second = store.authorize('session-a', intent.id)
  assert.equal(second.ok, true)
  assert.equal(intentCallCount(second.intent), 2)

  // The turn ending does not settle the route: the authorization outlives it, so
  // a run the model never got to start stays reachable in the next turn.
  store.endTurn('session-a', 1)
  assert.equal(store.get('session-a', intent.id).status, 'open')
  const nextTurn = authorizeRouteTool({
    sessionId: 'session-a',
    turn: 2,
    tool: 'external_research_design',
    openIntent: store.openIntent('session-a'),
  })
  assert.equal(nextTurn.allowed, true, 'the authorization died with the turn that carried its task text')

  // What does settle it is the task ending: a new command supersedes the route.
  assert.equal(open(store, { command: 'external-code' }).ok, true)
  const settled = authorizeRouteTool({
    sessionId: 'session-a',
    turn: 2,
    tool: 'external_research_design',
    openIntent: store.openIntent('session-a'),
    settledIntent: store.settledIntent('session-a', 'external_research_design'),
  })
  assert.equal(settled.allowed, false)
  // The settled plan route is refused, and the refusal names the route that now
  // owns the task rather than the one that was replaced.
  assert.match(settled.reason, /既に終了しました|対応しません/)
})

test('an authorized run is recorded without spending the authorization', () => {
  const store = new RoutingIntentStore()
  const { intent } = openDelivered(store, 1)
  const authorized = store.authorize('session-a', intent.id)
  assert.equal(authorized.ok, true)
  assert.equal(intentCallCount(authorized.intent), 1)

  // A run that reported nothing is recorded as such, because that is the fact a
  // later refusal has to state rather than reporting a completed review.
  store.recordCall(authorized.intent, { runId: undefined, resultStatus: 'error' })
  assert.equal(authorized.intent.calls.length, 1)
  assert.equal(authorized.intent.calls[0].runId, null)

  // The authorization survives the failed run, so the same task can retry.
  const retry = store.authorize('session-a', intent.id)
  assert.equal(retry.ok, true, `the failed run spent the authorization: ${retry.reason}`)
  assert.equal(intentCallCount(retry.intent), 2)
  store.recordCall(retry.intent, { runId: 'run-2', resultStatus: 'terminal' })
  assert.equal(retry.intent.calls.at(-1).resultStatus, 'terminal')

  store.endTurn('session-a', 1)
  store.closeSession('session-a', 'agent-disposed')
  const settled = authorizeRouteTool({
    sessionId: 'session-a',
    turn: 2,
    tool: 'external_research_design',
    openIntent: store.openIntent('session-a'),
    settledIntent: store.settledIntent('session-a', 'external_research_design'),
  })
  assert.equal(settled.allowed, false)
  assert.match(settled.reason, /2回のrun/)
  assert.match(settled.reason, /terminal/)
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

test('the newest plan command replaces the other plan route, one at a time', () => {
  // The exclusion is satisfied by the supersede rather than by a refusal: a task
  // never holds both plan routes, and the newer command is the instruction the
  // human means. Refusing instead would strand the task on a route the human has
  // already replaced — the same dead end the turn-scoped authorization produced.
  for (const [first, second] of [['external-plan', 'opus-plan'], ['opus-plan', 'external-plan']]) {
    const store = new RoutingIntentStore()
    const opened = openDelivered(store, 1, { command: first })
    assert.equal(opened.ok, true)
    const replacement = open(store, { command: second })
    assert.equal(replacement.ok, true, `${second} after ${first} was refused: ${replacement.reason}`)
    assert.equal(store.get('session-a', opened.intent.id).status, 'closed')
    assert.equal(store.get('session-a', opened.intent.id).closedReason, 'superseded-by-command')
    assert.equal(store.openIntent('session-a').command, second)
    // Exactly one of the two plan tools is live: the replaced one is not.
    const liveTools = ROUTE_TOOLS.filter(tool => store.hasUnsettledIntent('session-a', [tool]))
    assert.deepEqual(liveTools, [routeToolForCommand(second)],
      `the task holds the wrong live routes: ${JSON.stringify(liveTools)}`)
  }
  assert.deepEqual([...MUTUALLY_EXCLUSIVE_COMMANDS], ['external-plan', 'opus-plan'])
})

test('a plan route keeps the exclusive slot across turns until the task ends', () => {
  const store = new RoutingIntentStore()
  const first = openDelivered(store, 1, { command: 'external-plan' })
  const authorized = store.authorize('session-a', first.intent.id)
  assert.equal(authorized.ok, true)
  // The turn ending does not free the slot: the plan route is still the task's
  // route, and the other plan command replaces it rather than joining it.
  store.endTurn('session-a', 1)
  assert.equal(store.hasUnsettledIntent('session-a', ['external_research_design']), true,
    'a turn end freed the exclusive plan slot')
  const replacement = open(store, { command: 'opus-plan' })
  assert.equal(replacement.ok, true, `the replacement was refused: ${replacement.reason}`)
  assert.equal(store.get('session-a', first.intent.id).closedReason, 'superseded-by-command')
  assert.equal(store.hasUnsettledIntent('session-a', ['external_research_design']), false,
    'the replaced plan route is still live')

  // Disposal ends the task, which is what frees the slot for the next task.
  store.closeSession('session-a', 'agent-disposed')
  const second = open(store, { command: 'opus-plan' })
  assert.equal(second.ok, true, `a finished plan task still conflicted: ${second.reason}`)
})

test('a command delivered but not yet answered is still replaced, not duplicated', () => {
  const store = new RoutingIntentStore()
  const admitted = open(store, { command: 'external-plan' })
  assert.equal(admitted.ok, true)
  const replacement = open(store, { command: 'opus-plan' })
  assert.equal(replacement.ok, true, `the replacement was refused: ${replacement.reason}`)
  assert.equal(store.get('session-a', admitted.intent.id).status, 'closed')
  assert.equal(store.openIntent('session-a').command, 'opus-plan')
  assert.equal(store.size, 2, 'the replacement duplicated rather than replaced the route')
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

test('a turn end keeps the authorization and only forgets the delivery', () => {
  const store = new RoutingIntentStore()
  const { intent } = openDelivered(store, 1)
  assert.equal(store.deliveredIntentForTurn('session-a', 1).id, intent.id)
  store.endTurn('session-a', 1)
  // The delivery record is per turn, so it is dropped; the authorization is not.
  assert.equal(store.deliveredIntentForTurn('session-a', 1), undefined)
  assert.equal(store.get('session-a', intent.id).status, 'open')
  assert.equal(store.get('session-a', intent.id).closedReason, null)
  assert.equal(store.openIntent('session-a').id, intent.id)
  for (const turn of [1, 2, 7]) {
    assert.equal(authorizeRouteTool({
      sessionId: 'session-a',
      turn,
      tool: 'external_research_design',
      openIntent: store.openIntent('session-a'),
    }).allowed, true, `the authorization was refused in turn ${turn}`)
  }
})

test('a route whose task text has not arrived survives a turn end and binds later', () => {
  // The Web composer submits a command in its own turn and the task text is the
  // next turn, so settling the undelivered intent here would silently drop it.
  const store = new RoutingIntentStore()
  const { intent } = open(store)
  store.endTurn('session-a', 1)
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

test('the newest command owns the route and retires the earlier one', () => {
  const store = new RoutingIntentStore()
  const plan = openDelivered(store, 1)
  store.endTurn('session-a', 1)
  // A different route replaces the plan route rather than running beside it, so
  // one task still owns exactly one route.
  assert.equal(open(store, { command: 'opus-plan' }).ok, true)
  assert.equal(store.get('session-a', plan.intent.id).status, 'closed')
  assert.equal(store.get('session-a', plan.intent.id).closedReason, 'superseded-by-command')

  // Disposal settles what is live, and the next plan command then owns the slot
  // for a fresh task.
  store.closeSession('session-a', 'agent-disposed')
  const second = openDelivered(store, 2, { command: 'opus-plan' })
  assert.equal(second.intent.deliveredTurn, 2)
  // The retired route is refused and reports what it did, and the new one is the
  // only route reachable.
  const retired = authorizeRouteTool({
    sessionId: 'session-a',
    turn: 3,
    tool: 'external_research_design',
    openIntent: store.openIntent('session-a'),
    settledIntent: store.settledIntent('session-a', 'external_research_design'),
  })
  assert.equal(retired.allowed, false, 'the superseded route ran again')
  assert.match(retired.reason, /既に終了しました|対応しません/)
  assert.equal(authorizeRouteTool({
    sessionId: 'session-a',
    turn: 3,
    tool: 'external_opus_design',
    openIntent: store.openIntent('session-a'),
  }).allowed, true, 'the newest route was not reachable in a later turn')
  assert.equal(store.openIntent('session-a').tool, 'external_opus_design')
})

test('restart never resumes a persisted intent, and keeps the run record', () => {
  const store = new RoutingIntentStore()
  const first = openDelivered(store, 1)
  store.authorize('session-a', first.intent.id)
  store.recordCall(first.intent, { runId: undefined, resultStatus: 'error' })
  // The snapshot that survives a restart records the authorized run and its
  // outcome, which is what lets a later refusal say the run reported nothing.
  const live = JSON.parse(JSON.stringify(store.toState()))
  const persisted = live.intents.find(intent => intent.id === first.intent.id)
  assert.equal(persisted.status, 'open')
  assert.equal(persisted.callCount, 1)
  assert.deepEqual(persisted.calls.map(call => call.resultStatus), ['error'])

  // Disposal is what ends a route; a closed session leaves nothing live behind,
  // so the next plan command is admitted for a fresh task.
  store.closeSession('session-a', 'agent-disposed')

  const other = open(store, { command: 'opus-plan' })
  assert.equal(other.ok, true, `the plan route was refused: ${other.reason}`)

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
