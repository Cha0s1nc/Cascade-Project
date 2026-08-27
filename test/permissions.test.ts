import { test } from 'node:test'
import assert from 'node:assert/strict'
import { canDeleteMedia } from '../src/core/permissions.ts'

test('an administrator can delete, regardless of the content-deletion flags', () => {
  assert.equal(canDeleteMedia({ IsAdministrator: true }), true)
  assert.equal(canDeleteMedia({ IsAdministrator: true, EnableContentDeletion: false }), true)
})

test('a non-admin with the global content-deletion flag can delete', () => {
  assert.equal(canDeleteMedia({ IsAdministrator: false, EnableContentDeletion: true }), true)
})

test('a non-admin granted deletion on at least one folder can delete', () => {
  assert.equal(
    canDeleteMedia({ IsAdministrator: false, EnableContentDeletionFromFolders: ['lib1'] }),
    true
  )
})

test('a non-admin with no deletion rights at all cannot delete', () => {
  assert.equal(canDeleteMedia({ IsAdministrator: false }), false)
  assert.equal(
    canDeleteMedia({ IsAdministrator: false, EnableContentDeletion: false, EnableContentDeletionFromFolders: [] }),
    false
  )
})

test('a missing or null policy reads as no rights, not a crash', () => {
  assert.equal(canDeleteMedia(undefined), false)
  assert.equal(canDeleteMedia(null), false)
  assert.equal(canDeleteMedia({}), false)
})
