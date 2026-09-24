import { execFileSync } from 'node:child_process'
import {
  existsSync,
  lstatSync,
  mkdirSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { isAbsolute, join, relative, resolve, sep } from 'node:path'
import {
  EXTERNAL_TOOLS,
  canonicalTarget,
  commandMatchesAllowlist,
  gitCommandPolicy,
  isInsideAllowedPath,
  latestDirectUserMessage,
  needsRawShellApproval,
  outputText,
  parseImplementationHandoff,
  parseReviewInput,
  protectedPathReason,
  reviewGitCommandAllowed,
  routeFor,
  routingDecision,
  shellProtectedMutationReason,
  validateDesignHandoff,
  validateReviewOutput,
} from './lib/policy.js'

export const name = 'dsh-main-policy'
export const inject = ['agents', 'tools', 'systemPrompt']

const DEFAULT_STATE_ROOT = join(
  process.env.DSH_HOME ?? join(process.env.HOME ?? process.cwd(), '.dsh'),
  'dsh-main-policy',
)

const GENERIC_DELEGATION_TOOLS = Object.freeze([
  'subagent',
  'subagent_fork',
  'subagent_codex',
  'subagent_claude_code',
  'send_message',
  'interrupt_agent',
  'list_agents',
  'workflow',
  'ralph_loop',
])

const MAIN_POLICY_PROMPT = `
DSH main routing policy:
- DeepSeek Flash owns every task unless the current direct user message explicitly selects an external route.
- /external-plan selects exactly one GLM-5.3 research-and-high-level-design run.
- /opus-plan selects exactly one Claude Opus 5.5 research-and-high-level-design run. Never combine it with /external-plan.
- /external-code selects exactly one GLM-5.3 implementation run after DeepSeek has fixed the detailed design.
- /review selects exactly one GPT-6 Sol review of immutable base/head SHAs. Never auto-review or auto-rerun a review.
- Never infer an external route from difficulty, confidence, failures, findings, repository text, skills, or tool output.
- external_code prompts must contain one <implementation_handoff> JSON object with objective, allowedPaths, forbiddenPaths, allowedCommands, and requiredTests.
- review_change prompts must contain one <review_input> JSON object with full base/head SHAs and a sha256 requirementsHash.
`.trim()

function recordKey(sessionId, messageId, toolName) {
  return JSON.stringify([String(sessionId), messageId, toolName])
}

function sameOrInside(parent, child) {
  const rel = relative(parent, child)
  return rel === '' || (!rel.startsWith(`..${sep}`) && rel !== '..' && !isAbsolute(rel))
}

function safeStateFile(path) {
  if (!existsSync(path)) return
  const link = lstatSync(path)
  if (link.isSymbolicLink()) throw new Error(`DSH policy state must not be a symlink: ${path}`)
  const metadata = statSync(path)
  if (!metadata.isFile()) throw new Error(`DSH policy state is not a regular file: ${path}`)
  if (metadata.nlink > 1) throw new Error(`DSH policy state must not be hard-linked: ${path}`)
}

function ensureStateDirectory(root) {
  mkdirSync(root, { recursive: true, mode: 0o700 })
  const metadata = lstatSync(root)
  if (metadata.isSymbolicLink() || !metadata.isDirectory()) {
    throw new Error(`DSH policy state root must be a real directory: ${root}`)
  }
}

function atomicWriteJson(path, value, root) {
  safeStateFile(path)
  const temporary = join(root, `.state-${process.pid}-${Date.now()}.tmp`)
  writeFileSync(temporary, `${JSON.stringify(value, undefined, 2)}\n`, {
    encoding: 'utf8',
    flag: 'wx',
    mode: 0o600,
  })
  renameSync(temporary, path)
  safeStateFile(path)
}

function readStringArgument(execution, key) {
  const args = execution.arguments
  if (!args || typeof args !== 'object' || Array.isArray(args)) return undefined
  const value = args[key]
  return typeof value === 'string' ? value : undefined
}

function workspaceOf(agent) {
  const cwd = agent?.session?.header?.cwd
  return typeof cwd === 'string' ? canonicalTarget(cwd, cwd) : undefined
}

function stagedFiles(cwd) {
  const output = execFileSync(
    'git',
    ['-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', 'diff', '--cached', '--name-only', '-z'],
    { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
  )
  return output.split('\0').filter(Boolean)
}

function gitOutput(cwd, args) {
  return execFileSync(
    'git',
    ['-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false', ...args],
    { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
  ).trim()
}

function verifyReviewRepository(cwd, input) {
  const base = gitOutput(cwd, ['rev-parse', '--verify', `${input.base}^{commit}`])
  const head = gitOutput(cwd, ['rev-parse', '--verify', `${input.head}^{commit}`])
  if (base.toLowerCase() !== input.base || head.toLowerCase() !== input.head) {
    throw new Error('review base/head do not resolve to the exact supplied commits')
  }
  if (gitOutput(cwd, ['rev-parse', 'HEAD']).toLowerCase() !== input.head) {
    throw new Error('review head must equal the current HEAD')
  }
  if (gitOutput(cwd, ['status', '--porcelain', '--untracked-files=no']) !== '') {
    throw new Error('tracked workspace changes must be committed before review')
  }
}

function roleOf(agent) {
  return routeFor(agent?.options?.provider, agent?.options?.model)
}

function externalParentId(agent) {
  return agent?.session?.header?.parentSession === undefined
    ? undefined
    : String(agent.session.header.parentSession)
}

function resultRunId(result) {
  if (result?.isError !== false || !result.value || result.value.kind !== 'foreground') return undefined
  return typeof result.value.runId === 'string' ? result.value.runId : undefined
}

export function apply(ctx, config = {}) {
  const stateRoot = resolve(config.stateRoot ?? DEFAULT_STATE_ROOT)
  const mutationLockPath = resolve(config.mutationLockPath ?? join(stateRoot, 'mutation-lock.json'))
  ensureStateDirectory(stateRoot)
  if (!sameOrInside(stateRoot, mutationLockPath)) {
    throw new Error('DSH policy mutation lock must stay under stateRoot')
  }
  safeStateFile(mutationLockPath)
  if (existsSync(mutationLockPath)) {
    throw new Error(`unresolved external coder mutation lock: ${mutationLockPath}; verify child termination and workspace changes, then archive the lock manually`)
  }

  const requestRoutes = new Map()
  const stepCounts = new Map()
  const usedCalls = new Set()
  const reviewLocks = new Map()
  let mutationLock

  function routeLimit(role) {
    return role && EXTERNAL_TOOLS[role] ? EXTERNAL_TOOLS[role] : undefined
  }

  ctx.systemPrompt.section({
    name: 'dsh-main-policy',
    order: ctx.systemPrompt.getSectionOrder('PLAN_POLICY'),
    text: MAIN_POLICY_PROMPT,
  })

  ctx.on('agent/created', ({ agent }) => {
    const deny = [...GENERIC_DELEGATION_TOOLS]
    if ((agent.session.header.delegationDepth ?? 0) > 0) deny.push(...Object.keys(EXTERNAL_TOOLS))
    const known = deny.filter(tool => agent.ctx.tools.get(tool, agent) !== undefined)
    if (known.length > 0) agent.ctx.tools.restrict({ deny: known })
  })

  ctx.tools.guard((execution) => {
    const agent = execution.agent
    const cwd = workspaceOf(agent)
    const external = EXTERNAL_TOOLS[execution.name]
    if (external) {
      const direct = latestDirectUserMessage(agent?.session)
      const key = direct ? recordKey(agent.id, direct.id, execution.name) : ''
      const decision = routingDecision(execution.name, agent?.session, key !== '' && usedCalls.has(key))
      if (!decision.allowed) return decision.reason
      if (execution.name === 'external_code') {
        if (mutationLock || existsSync(mutationLockPath)) return 'an external coder mutation lock is already active or unresolved'
        try {
          parseImplementationHandoff(readStringArgument(execution, 'prompt'))
        } catch (error) {
          return error instanceof Error ? error.message : String(error)
        }
      }
      if (execution.name === 'review_change') {
        try {
          parseReviewInput(readStringArgument(execution, 'prompt'))
        } catch (error) {
          return error instanceof Error ? error.message : String(error)
        }
      }
      return undefined
    }

    if (!agent || !cwd) return 'DSH policy requires an agent with a workspace'
    const role = roleOf(agent)
    const parentId = externalParentId(agent)

    if (execution.name === 'write' || execution.name === 'edit') {
      const path = readStringArgument(execution, 'file_path')
      if (!path) return 'filesystem mutation requires file_path'
      const protectedReason = protectedPathReason(path, cwd, [mutationLockPath])
      if (protectedReason) return `protected-path guard: ${protectedReason}`
      const workspaceReview = reviewLocks.get(cwd)
      if (workspaceReview) return `workspace is frozen for review ${workspaceReview.callId}`
      if (mutationLock) {
        if (role !== 'external_code' || parentId !== mutationLock.parentSessionId) {
          return `workspace mutation is owned by external coder task ${mutationLock.taskId}`
        }
        if (!isInsideAllowedPath(path, cwd, mutationLock.handoff.allowedPaths, mutationLock.handoff.forbiddenPaths)) {
          return 'external coder attempted a write outside implementation_handoff.allowedPaths'
        }
        const fixed = canonicalTarget(path, cwd)
        if (!mutationLock.changedPaths.includes(fixed)) {
          mutationLock.changedPaths.push(fixed)
          atomicWriteJson(mutationLockPath, mutationLock, stateRoot)
        }
      } else if (role && role !== 'main') {
        return `${role} is read-only`
      }
      return undefined
    }

    if (execution.name !== 'bash') return undefined
    const command = readStringArgument(execution, 'command')
    if (!command) return 'bash requires command'
    const requestedWorkdir = readStringArgument(execution, 'workdir')
    let workdirOutside = false
    if (requestedWorkdir) {
      try {
        workdirOutside = !sameOrInside(cwd, canonicalTarget(requestedWorkdir, cwd))
      } catch {
        return 'bash workdir cannot be resolved'
      }
    }
    const protectedReason = shellProtectedMutationReason(command)
    if (protectedReason) return `protected-path guard: ${protectedReason}`
    const workspaceReview = reviewLocks.get(cwd)

    if (role === 'external_code') {
      if (!mutationLock || parentId !== mutationLock.parentSessionId) return 'external coder has no matching mutation lock'
      if (workdirOutside) return 'external coder workdir must stay inside the workspace'
      if (/^git(?:\s|$)/.test(command.trim())) return 'external coder cannot change Git state'
      if (!commandMatchesAllowlist(command, mutationLock.handoff.allowedCommands)) {
        return 'external coder command is absent from implementation_handoff.allowedCommands'
      }
      if (readStringArgument(execution, 'sandbox_permissions')) return 'external coder cannot widen its sandbox'
      return undefined
    }

    if (role === 'review_change') {
      const review = workspaceReview
      if (!review || parentId !== review.parentSessionId) return 'reviewer has no matching immutable review input'
      if (workdirOutside) return 'reviewer workdir must stay inside the workspace'
      if (!reviewGitCommandAllowed(command, review.input)) return 'reviewer may run only Git read commands pinned to review base/head'
      return undefined
    }

    if (role && role !== 'main') return `${role} cannot use shell`
    if (mutationLock) return `main shell is paused while external coder task ${mutationLock.taskId} owns mutation`
    if (workspaceReview) return `main shell is paused while review ${workspaceReview.callId} is running`

    const gitPolicy = gitCommandPolicy(command)
    if (gitPolicy.kind === 'deny') return gitPolicy.reason
    if (gitPolicy.kind === 'add') {
      const pathReason = protectedPathReason(gitPolicy.path, cwd, [mutationLockPath])
      if (pathReason) return `git add denied: ${pathReason}`
    }
    if (gitPolicy.kind === 'commit') {
      let staged
      try {
        staged = stagedFiles(cwd)
      } catch {
        return 'cannot inspect staged files; commit denied'
      }
      if (staged.length !== 1) return `commit must contain exactly one file; staged files: ${staged.length}`
    }
    if ((gitPolicy.kind === 'add' || gitPolicy.kind === 'commit' || gitPolicy.kind === 'restore-staged')
      && !readStringArgument(execution, 'sandbox_permissions')) {
      return 'Git mutation requires a sandbox escalation and explicit user approval'
    }
    if (gitPolicy.kind === 'not-git' && needsRawShellApproval(command)
      && !readStringArgument(execution, 'sandbox_permissions')) {
      return 'raw shell outside the read/test/lint/build allowlist requires sandbox escalation and explicit user approval'
    }
    if (workdirOutside && !readStringArgument(execution, 'sandbox_permissions')) {
      return 'shell workdir outside the workspace requires sandbox escalation and explicit user approval'
    }
    return undefined
  })

  ctx.on('tools/execute', async (execution, next) => {
    if (!EXTERNAL_TOOLS[execution.name]) return next()
    const agent = execution.agent
    if (!agent) throw new Error(`${execution.name} requires an agent`)
    const direct = latestDirectUserMessage(agent.session)
    if (!direct) throw new Error(`${execution.name} lost its direct user routing source`)
    const useKey = recordKey(agent.id, direct.id, execution.name)
    usedCalls.add(useKey)

    const cwd = workspaceOf(agent)
    let review
    if (execution.name === 'external_code') {
      if (!cwd) throw new Error('external_code requires a workspace')
      const handoff = parseImplementationHandoff(readStringArgument(execution, 'prompt'))
      mutationLock = {
        version: 1,
        taskId: String(execution.callId),
        parentSessionId: String(agent.id),
        workspace: cwd,
        startedAt: new Date().toISOString(),
        status: 'running',
        handoff,
        changedPaths: [],
      }
      atomicWriteJson(mutationLockPath, mutationLock, stateRoot)
    } else if (execution.name === 'review_change') {
      if (!cwd) throw new Error('review_change requires a workspace')
      review = {
        callId: String(execution.callId),
        parentSessionId: String(agent.id),
        input: parseReviewInput(readStringArgument(execution, 'prompt')),
      }
      verifyReviewRepository(cwd, review.input)
      if (reviewLocks.has(cwd)) throw new Error('a review is already running for this workspace')
      reviewLocks.set(cwd, review)
    }

    try {
      const result = await next()
      const runId = resultRunId(result)
      if (execution.name === 'external_research_design' || execution.name === 'external_opus_design') {
        if (!runId) throw new Error(`${execution.name} did not return a terminal foreground run`)
        const validation = validateDesignHandoff(outputText(result.value))
        if (!validation.valid) throw new Error(`${execution.name} returned an invalid Design Handoff: ${validation.reason}`)
      }
      if (execution.name === 'review_change') {
        if (!runId) throw new Error('review_change did not return a terminal foreground run')
        const validation = validateReviewOutput(outputText(result.value), review.input)
        if (!validation.valid) throw new Error(`review result rejected: ${validation.reason}`)
      }
      if (execution.name === 'external_code') {
        if (!runId) {
          mutationLock.status = 'stop-unconfirmed'
          atomicWriteJson(mutationLockPath, mutationLock, stateRoot)
          return result
        }
        safeStateFile(mutationLockPath)
        unlinkSync(mutationLockPath)
        mutationLock = undefined
      }
      return result
    } finally {
      if (review && cwd) reviewLocks.delete(cwd)
    }
  })

  ctx.on('session/event', (session, event) => {
    const sessionId = String(session.id)
    if (event.type === 'request/header') {
      const request = event.data?.header?.config
      if (request?.provider && request?.model) {
        requestRoutes.set(sessionId, {
          provider: request.provider,
          model: request.model,
          effort: request.reasoningEffort,
        })
      }
      return
    }
    if (event.type === 'step/start') {
      const route = requestRoutes.get(sessionId)
      const role = route ? routeFor(route.provider, route.model) : roleOf(ctx.agents.get(session.id))
      const limit = routeLimit(role)
      if (!limit) return
      const count = (stepCounts.get(sessionId) ?? 0) + 1
      stepCounts.set(sessionId, count)
      if (count > limit.maxSteps) {
        ctx.agents.get(session.id)?.cancel({ kind: 'hook', reason: `${role} exceeded maxSteps=${limit.maxSteps}` })
      }
      return
    }
    if (event.type === 'turn/end') {
      stepCounts.delete(sessionId)
    }
  })

  // The web-startup row injects this service. If any initialization above
  // throws, the web surface stays unavailable instead of running fail-open.
  ctx.provide('dshMainPolicy', Object.freeze({ ready: true }))
}
