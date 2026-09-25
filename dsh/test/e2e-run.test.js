/**
 * The end-to-end half, reachable from the unit suite.
 *
 * `npm run verify` is the documented entry point and runs this file too. It also
 * runs here, by default, because the end-to-end run is the only thing that
 * proves the bundle works in a real profile, and a verification that is
 * reachable only through one script is a verification that can quietly stop
 * happening.
 *
 * It boots real DSH profiles with a throwaway home, a throwaway workspace, and a
 * loopback mock provider, so it needs no credentials and reaches no network
 * provider. `DSH_DISABLE_E2E=1` skips it for a fast unit-only run.
 */

import test from 'node:test'

if (process.env.DSH_DISABLE_E2E === '1') {
  test('e2e: skipped because DSH_DISABLE_E2E=1', { skip: 'DSH_DISABLE_E2E=1' }, () => {})
} else {
  // Imported rather than spawned: a nested `node --test` invocation on this
  // platform completes with no output at all, which would report success for a
  // suite that never ran. Importing registers the end-to-end tests with the
  // runner that is already executing, so their failures reach this process.
  await import('./e2e/workflows.test.js')
}
