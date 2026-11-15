import { test } from 'node:test'
import assert from 'node:assert/strict'
import { safeHref } from '../src/ui/href.ts'

test('safeHref keeps http(s) links and drops script, data and junk', () => {
  assert.equal(safeHref('https://example.com/auth?x=1')?.host, 'example.com')
  assert.equal(safeHref('http://localhost:3000/')?.port, '3000')
  for (const bad of ['javascript:alert(1)', ' JavaScript:alert(1)', 'data:text/html,<b>', 'not a url', '', undefined]) {
    assert.equal(safeHref(bad), undefined, String(bad))
  }
})
