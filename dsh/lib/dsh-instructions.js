/**
 * The DSH-specific context injected into every DSH main session.
 *
 * The text lives in `AGENTS.dsh.md` so it is readable as a document, and this
 * module reads that exact file rather than carrying a second copy: a guidance
 * file that exists in two places drifts, and the drifted half is the one the
 * model actually sees.
 *
 * The content stays deliberately small. The profile's own system prompt already
 * carries generic engineering guidance, and the workspace `AGENTS.md` is the
 * shared contract. What must be stated here is only what DSH main cannot infer
 * from those sources — which owner each responsibility has in this routing
 * model, and that the Codex/Claude legacy routing documents in the workspace do
 * not apply to DSH main.
 *
 * A missing or unreadable file is a deployment fault, not a warning: this module
 * is imported during plugin activation, so a bundle that cannot state its own
 * routing rules fails profile startup instead of running without them.
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/** The marker pair that delimits the injected body inside `AGENTS.dsh.md`. */
export const INSTRUCTION_MARKERS = Object.freeze({
  begin: '<!-- BEGIN DSH_INSTRUCTIONS -->',
  end: '<!-- END DSH_INSTRUCTIONS -->',
})

/**
 * Extract the injected body from the documentation file that holds it.
 *
 * The markers are matched as whole lines rather than as arbitrary substrings:
 * the prose above the block names them, and a substring search would take that
 * mention for the block itself and extract whatever sits between the two.
 *
 * @param text - the contents of `AGENTS.dsh.md`.
 * @returns the trimmed instruction body.
 * @throws when the marker pair is absent or empty, because a silent empty
 *   section would disable every routing rule without failing anything.
 */
export function extractInstructions(text) {
  const lines = String(text).split(/\r?\n/)
  const isMarker = (line, marker) => line.trim() === marker
  const begin = lines.findIndex(line => isMarker(line, INSTRUCTION_MARKERS.begin))
  if (begin === -1) throw new Error(`AGENTS.dsh.md has no ${INSTRUCTION_MARKERS.begin} line`)
  const end = lines.findIndex((line, index) => index > begin && isMarker(line, INSTRUCTION_MARKERS.end))
  if (end === -1) throw new Error(`AGENTS.dsh.md has no ${INSTRUCTION_MARKERS.end} line`)
  const body = lines.slice(begin + 1, end).join('\n').trim()
  if (body === '') throw new Error('AGENTS.dsh.md carries an empty instruction block')
  return body
}

/** Resolve `AGENTS.dsh.md` from this module's own installed location. */
export function instructionsFile(moduleUrl = import.meta.url) {
  return join(dirname(fileURLToPath(moduleUrl)), '..', 'AGENTS.dsh.md')
}

/** Read the instruction body from disk, failing loudly when it is unusable. */
export function loadInstructions(moduleUrl = import.meta.url) {
  const path = instructionsFile(moduleUrl)
  let text
  try {
    text = readFileSync(path, 'utf8')
  } catch (error) {
    throw new Error(`DSH instructions cannot be read (${path}): ${error instanceof Error ? error.message : String(error)}`)
  }
  return extractInstructions(text)
}

/** Section order: immediately after PLAN_POLICY, before the workspace reminder. */
export const DSH_INSTRUCTIONS = loadInstructions()
