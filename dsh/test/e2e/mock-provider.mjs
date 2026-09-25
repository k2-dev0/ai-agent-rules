/**
 * Local mock LLM provider for the DSH end-to-end run.
 *
 * It speaks the `openai-completions` protocol DSH's pi-ai adapter uses, on
 * loopback only, so the E2E never contacts a real provider and never bills an
 * account. Responses are scripted per call so the run is deterministic.
 *
 * The server also records every request it receives, which is how the E2E
 * proves that repository text, skill bodies, or tool output never turned into a
 * routing instruction: the recorded prompts are inspected after the run.
 */

import { createServer } from 'node:http'

const PORT_ENV = 'DSH_E2E_MOCK_PORT'

/** A tool call in the OpenAI chat-completions shape. */
function toolCall(id, name, args) {
  return {
    id,
    type: 'function',
    function: { name, arguments: JSON.stringify(args) },
  }
}

function chunk(delta, finishReason = null) {
  return {
    id: 'chatcmpl-mock',
    object: 'chat.completion.chunk',
    created: Math.floor(Date.now() / 1000),
    model: 'mock-1',
    choices: [{ index: 0, delta, finish_reason: finishReason }],
  }
}

/**
 * Start the mock provider.
 *
 * @param options - scripted steps keyed by the tool name the model should call.
 * @returns the server, its base URL, and the recorded requests.
 */
export async function startMockProvider({ steps = [], requireToolCall = true } = {}) {
  const requests = []
  const queue = [...steps]

  const server = createServer((request, response) => {
    let body = ''
    request.on('data', (part) => { body += part })
    request.on('end', () => {
      let parsed
      try {
        parsed = JSON.parse(body)
      } catch {
        parsed = body
      }
      if (request.url?.endsWith('/models')) {
        response.writeHead(200, { 'content-type': 'application/json' })
        response.end(JSON.stringify({ data: [{ id: 'mock-1' }] }))
        return
      }
      requests.push({ url: request.url, body: parsed })
      const step = queue.shift()
      const toolCalls = step?.toolCalls ?? []
      if (requireToolCall && toolCalls.length === 0 && queue.length >= 0 && !step?.text) {
        // No script left: answer with plain text so the turn terminates.
      }
      response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' })
      const deltas = []
      if (step?.text) {
        deltas.push(chunk({ role: 'assistant', content: step.text }))
      } else if (toolCalls.length > 0) {
        deltas.push(chunk({
          role: 'assistant',
          content: null,
          tool_calls: toolCalls.map((call, index) => ({
            index,
            id: call.id,
            type: 'function',
            function: call.function.name === undefined
              ? call.function
              : { name: call.function.name, arguments: '' },
          })),
        }))
        deltas.push(chunk({
          role: 'assistant',
          content: null,
          tool_calls: toolCalls.map((call, index) => ({
            index,
            function: { arguments: call.function.arguments },
          })),
        }, 'tool_calls'))
      } else {
        deltas.push(chunk({ role: 'assistant', content: step?.text ?? 'ok' }, 'stop'))
      }
      let payload = ''
      for (const item of deltas) payload += `data: ${JSON.stringify(item)}\n\n`
      payload += 'data: [DONE]\n\n'
      response.end(payload)
    })
  })

  await new Promise((resolveListener) => server.listen(0, '127.0.0.1', resolveListener))
  const address = server.address()
  return {
    server,
    port: address.port,
    baseURL: `http://127.0.0.1:${address.port}/v1`,
    requests,
    remaining: () => queue.length,
    async close() {
      await new Promise(resolveClose => server.close(resolveClose))
    },
  }
}

/** The mock route patch applied with `--patch` so the real profile reaches it. */
export function mockProviderPatch(baseURL) {
  return `# E2E-only mock provider route. Applied with --patch; never part of the bundle.
- id: llm-pi-ai
  config:
    providers:
      mock:
        apiKeyEnv: DSH_E2E_MOCK_API_KEY
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

export const MOCK_PORT_ENV = PORT_ENV
