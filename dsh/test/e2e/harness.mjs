/**
 * Shared E2E harness for the DSH main profile.
 *
 * The harness always works against a throwaway `DSH_HOME`, a throwaway Git
 * workspace, and a local mock provider, so no test can reach a real provider or
 * bill an account. Everything it asserts is produced by the real DSH
 * `0.1.7-rc.1` CLI or by the real profile boot; nothing is simulated in place of
 * DSH behavior.
 */

import { spawnSync } from 'node:child_process'
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const bundleRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
export const repositoryRoot = resolve(bundleRoot, '..')

/**
 * Placeholder credential for the loopback mock provider.
 *
 * The mock route references this name through `apiKeyEnv`, so the E2E exercises
 * the real credential-resolution path without any real key. The secret-scanning
 * assertions compare against the same value, so any credential value reaching
 * state or logs fails the run.
 */
export const MOCK_CREDENTIAL = 'dsh-e2e-loopback-placeholder'
export const MOCK_CREDENTIAL_ENV = 'DSH_E2E_MOCK_API_KEY'

/**
 * Remove the temporary inode-rewrite helpers used while this bundle was being
 * developed. They are scaffolding, never part of the distribution.
 */
export function removeIterationHelpers() {
  const removed = []
  // A file edited while hard-linked to an installed profile could only be
  // replaced through a temporary copy, and an interrupted run leaves that copy
  // behind. Neither is part of the distribution.
  const scratch = /^(?:tmp-[a-z0-9-]+\.(?:test\.js|mjs)|.+\.[a-z]+\.rw-\d+|.+\.[a-z]+\.(?:fresh|break|relink)-\d+)$/
  for (const dir of [bundleRoot, join(bundleRoot, 'test'), join(bundleRoot, 'test', 'e2e')]) {
    let entries
    try {
      entries = readdirSync(dir)
    } catch {
      continue
    }
    for (const entry of entries) {
      if (!scratch.test(entry)) continue
      rmSync(join(dir, entry), { force: true })
      removed.push(`${dir.slice(bundleRoot.length + 1)}/${entry}`)
    }
  }
  return removed
}

/** Locate the installed DSH CLI this bundle was verified against. */
export function resolveDshBin() {
  const candidates = []
  if (process.env.DSH_BIN) candidates.push(process.env.DSH_BIN)
  const which = spawnSync('which', ['dsh'], { encoding: 'utf8' })
  if (which.status === 0 && which.stdout.trim() !== '') {
    candidates.push(realpathSync(which.stdout.trim()))
  }
  candidates.push('/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/lib/bin.js')
  candidates.push('/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js')
  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return realpathSync(candidate)
  }
  throw new Error('cannot locate the installed dsh CLI; set DSH_BIN to <install>/lib/bin.js')
}

/** Read the DSH version this bundle pins and require the installed one to match. */
export function assertDshVersion() {
  const pinned = readFileSync(join(bundleRoot, '.dsh-version'), 'utf8').trim()
  const bin = resolveDshBin()
  const installed = JSON.parse(
    readFileSync(join(dirname(bin), '..', 'package.json'), 'utf8'),
  ).version
  if (installed !== pinned) {
    throw new Error(`DSH version mismatch: bundle pins ${pinned}, installed is ${installed}`)
  }
  return { bin, version: installed }
}

/**
 * Create one throwaway environment: isolated home, scratch workspace, and the
 * profile that carries this bundle.
 */
export function createEnvironment({ profile = 'dsh-main', template = 'web', workspace = 'workspace' } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'dsh-main-e2e-'))
  const home = join(root, 'home')
  const workdir = join(root, workspace)
  mkdirSync(home, { recursive: true })
  mkdirSync(workdir, { recursive: true })
  return {
    root,
    home,
    workdir,
    profile,
    template,
    cleanup() {
      rmSync(root, { recursive: true, force: true })
    },
  }
}

/**
 * Boot arguments for a real web-profile run.
 *
 * Launcher options must precede the app's own arguments: the first token the
 * launcher does not recognize starts the app's argument list, so `--patch`
 * placed after `--port` would be handed to the web app and rejected.
 *
 * `--no-open` is required here. The web surface otherwise hands its
 * authenticated URL to the default browser, and because every E2E run uses a
 * throwaway `DSH_HOME`, the "first run" notice appears again each time — which
 * reads as a pop-up loop to whoever is using the machine. `--port 0` asks for an
 * ephemeral port so a real `dsh web` on the default port is never contended
 * with.
 */
export function webBootArgs(env, patches) {
  return [
    '--profile', env.profile,
    ...patches.flatMap(patch => ['--patch', patch]),
    '--port', '0',
    '--no-open',
  ]
}

/**
 * Run the real DSH CLI with an isolated home.
 *
 * `SIGKILL` on timeout matters because a boot keeps a web listener alive, so a
 * graceful kill can leave the server and its browser tab behind.
 */
export function runDsh(env, args, options = {}) {
  const bin = options.bin ?? resolveDshBin()
  const result = spawnSync(process.execPath, [bin, ...args], {
    cwd: options.cwd ?? env.workdir,
    encoding: 'utf8',
    timeout: options.timeoutMs ?? 900_000,
    killSignal: 'SIGKILL',
    env: {
      ...process.env,
      DSH_HOME: env.home,
      DSH_AGENTS_HOME: join(env.root, 'agents'),
      HOME: env.root,
      // Every route resolves from the loopback placeholder, so no real
      // credential is read and no real provider can be reached.
      DEEPSEEK_API_KEY: MOCK_CREDENTIAL,
      ZAI_API_KEY: MOCK_CREDENTIAL,
      ANTHROPIC_API_KEY: MOCK_CREDENTIAL,
      OPENAI_API_KEY: MOCK_CREDENTIAL,
      [MOCK_CREDENTIAL_ENV]: MOCK_CREDENTIAL,
      ...options.env,
    },
  })
  return {
    status: result.status,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
    signal: result.signal,
    error: result.error,
  }
}

/** Initialize the profile from a shipped template. */
export function initializeProfile(env) {
  const created = runDsh(env, ['--profile', env.profile, '--from-default-profile', env.template, '--help'])
  if (created.status !== 0) {
    throw new Error(`profile initialization failed (${created.status}): ${created.stderr || created.stdout}`)
  }
  const manifestPath = join(env.home, 'profiles', env.profile, 'package.json')
  if (!existsSync(manifestPath)) throw new Error(`profile manifest missing after initialization: ${manifestPath}`)
  return manifestPath
}

/** Install this bundle into the profile with the real plugin manager. */
export function installBundle(env, { offline = false } = {}) {
  const args = ['plugin', '--profile', env.profile, 'add', `file:${bundleRoot}`]
  if (offline) args.push('--offline')
  const installed = runDsh(env, args)
  if (installed.status !== 0) {
    throw new Error(`bundle install failed (${installed.status}): ${installed.stderr || installed.stdout}`)
  }
  const manifest = JSON.parse(readFileSync(join(env.home, 'profiles', env.profile, 'package.json'), 'utf8'))
  const bundles = manifest?.dsh?.profile?.bundles ?? []
  if (!bundles.includes('@kaikojima/dsh-main-policy')) {
    throw new Error(`bundle install did not register the bundle layer: ${JSON.stringify(bundles)}`)
  }
  return bundles
}

/** Dump the composed profile tree. */
export function dumpConfig(env) {
  const dumped = runDsh(env, ['--profile', env.profile, '--dump-config'])
  if (dumped.status !== 0) {
    throw new Error(`--dump-config failed (${dumped.status}): ${dumped.stderr || dumped.stdout}`)
  }
  return dumped.stdout
}

/** Create a disposable Git repository with a deterministic first commit. */
export function createGitWorkspace(env) {
  const git = (...args) => {
    const result = spawnSync('git', args, { cwd: env.workdir, encoding: 'utf8' })
    if (result.status !== 0) throw new Error(`git ${args.join(' ')} failed: ${result.stderr}`)
    return result.stdout.trim()
  }
  git('init', '--quiet', '--initial-branch=main')
  git('config', 'user.email', 'e2e@example.invalid')
  git('config', 'user.name', 'DSH E2E')
  git('config', 'commit.gpgsign', 'false')
  writeFileSync(join(env.workdir, 'README.md'), '# e2e workspace\n')
  mkdirSync(join(env.workdir, 'src'), { recursive: true })
  writeFileSync(join(env.workdir, 'src', 'app.js'), 'export const value = 1\n')
  git('add', 'README.md')
  git('commit', '--quiet', '-m', 'test: add readme')
  git('add', 'src/app.js')
  git('commit', '--quiet', '-m', 'feat: add app')
  return {
    revParse: ref => git('rev-parse', ref),
    log: () => git('log', '--format=%H %s'),
    status: () => git('status', '--porcelain'),
    git,
  }
}

/** Copy the bundle into a stable out-of-repo location so no source path leaks in. */
export function stageBundleCopy(env) {
  const staged = join(env.root, 'staged-bundle')
  cpSync(bundleRoot, staged, {
    recursive: true,
    filter: source => !source.includes('node_modules'),
  })
  return staged
}
