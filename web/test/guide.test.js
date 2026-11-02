import assert from 'node:assert/strict'
import { test } from 'node:test'
import { offersGuide } from '../src/api.js'

const status = (epg) => ({ epg })

test('the three ordinary waves are on offer whatever has been read', () => {
  for (const type of ['td', 'bs', 'cs']) {
    assert.equal(offersGuide(status({ [type]: { channels: 0 } }), type), true)
    assert.equal(offersGuide(null, type), true)
  }
})

test('a 4K wave is on offer once the recorder has given a channel of it', () => {
  assert.equal(offersGuide(status({ bs4k: { channels: 12 } }), 'bs4k'), true)
})

test('a 4K wave nothing was read of is not on offer', () => {
  assert.equal(offersGuide(status({ bs4k: { channels: 0 } }), 'bs4k'), false)
  assert.equal(offersGuide(status({}), 'cs4k'), false)
  assert.equal(offersGuide(null, 'bs4k'), false)
})
