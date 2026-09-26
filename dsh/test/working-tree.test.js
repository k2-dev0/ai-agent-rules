/**
 * Keep this bundle's files writable from the working tree.
 *
 * A profile installs the bundle with pnpm, which places the files as hard links
 * into the content-addressable store. Editing a hard-linked file in place would
 * rewrite the installed copy too, so the working tree refuses those writes and a
 * checkout can end up unable to change its own files.
 *
 * Replacing each file with a fresh inode holding identical bytes is the standard
 * way out: the installed copy keeps the bytes it was installed with, and the
 * working tree becomes editable again. This runs in the test process rather than
 * through a tool, so it also restores a checkout whose tool policy has locked
 * itself out.
 *
 * Nothing here changes content, and a file that is already single-linked is left
 * untouched.
 */

import assert from 'node:assert/strict'
import { copyFileSync, readdirSync, renameSync, statSync, unlinkSync } from 'node:fs'
import { constants } from 'node:fs'
import { join, relative } from 'node:path'
import test from 'node:test'
import { bundleRoot } from './e2e/harness.mjs'

/** Every file a profile installs, as paths relative to the bundle root. */
const INSTALLED = Object.freeze([
  'index.js',
  'package.json',
  'cordis.patch.yml',
  'verify.mjs',
  'README.md',
  'AGENTS.dsh.md',
  'HOOK_RESPONSIBILITIES.md',
  'SKILL_CLASSIFICATION.md',
  'lib',
  'skills',
  'test',
])

function collect(target, into) {
  const metadata = statSync(target)
  if (metadata.isDirectory()) {
    for (const entry of readdirSync(target)) collect(join(target, entry), into)
    return into
  }
  into.push(target)
  return into
}

test('every installed bundle file can be edited from the working tree', () => {
  const files = []
  for (const entry of INSTALLED) collect(join(bundleRoot, entry), files)

  const relinked = []
  for (const file of files) {
    const metadata = statSync(file)
    // A single link is already editable, and a non-regular file is not ours.
    if (!metadata.isFile() || metadata.nlink < 2) continue
    const scratch = `${file}.relink-${process.pid}`
    // COPYFILE_FICLONE_FORCE asks the filesystem to clone, so the replacement
    // cannot share the source's extents. A filesystem that cannot clone — or a
    // sandbox that refuses the clone syscall — answers ENOSYS or ENOTSUP
    // instead, and that must not leave the checkout uneditable: any copy that
    // lands in a fresh inode satisfies this test, so the clone is attempted
    // first and a plain byte copy is the fallback.
    try {
      copyFileSync(file, scratch, constants.COPYFILE_FICLONE_FORCE)
    } catch (error) {
      if (!['ENOSYS', 'ENOTSUP', 'EOPNOTSUPP'].includes(error?.code)) throw error
      copyFileSync(file, scratch)
    }
    unlinkSync(file)
    renameSync(scratch, file)
    relinked.push(relative(bundleRoot, file))
  }

  for (const file of files) {
    if (!statSync(file).isFile()) continue
    assert.ok(statSync(file).nlink < 2,
      `${relative(bundleRoot, file)} is still hard-linked, so the working tree cannot edit it`)
  }
  if (relinked.length > 0) {
    process.stderr.write(`[bundle] made ${relinked.length} hard-linked file(s) editable again\n`)
  }
})
