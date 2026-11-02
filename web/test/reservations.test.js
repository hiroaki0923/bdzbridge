import assert from 'node:assert/strict'
import { test } from 'node:test'
import { reservationAgain, RESERVATION_CHANGED, RESERVATION_NOT_LISTED } from '../src/api.js'

const row = (over = {}) => ({
  id: '0x1', broadcasting: 'td', service_id: 1024, event_id: 100, start: '2026-11-02T21:00:00+09:00',
  creator: '1100', created_by_app: false, ...over,
})

test('an id still on its programme is the reservation, though its start moved with the broadcast', () => {
  const now = row({ start: '2026-11-02T21:10:00+09:00' })
  assert.equal(reservationAgain([now], row()).row, now)
})

test('an id now on another programme is not written to', () => {
  assert.deepEqual(reservationAgain([row({ event_id: 101 })], row()), { why: RESERVATION_CHANGED })
  assert.deepEqual(reservationAgain([row({ service_id: 1025 })], row()), { why: RESERVATION_CHANGED })
})

test('a reservation made by its times is told by its start', () => {
  const held = row({ event_id: null })
  assert.deepEqual(reservationAgain([held], held).row, held)
  assert.deepEqual(reservationAgain([row({ event_id: null, start: '2026-11-09T21:00:00+09:00' })], held), { why: RESERVATION_CHANGED })
})

test('a reservation the recorder renumbered is found by its channel, start, programme and maker', () => {
  const renumbered = row({ id: '0x2' })
  assert.equal(reservationAgain([renumbered], row()).row, renumbered)
})

test('a row by another maker does not stand in for one deleted on the recorder', () => {
  const others = row({ id: '0x2', creator: '2200', created_by_app: true })
  assert.deepEqual(reservationAgain([others], row()), { why: RESERVATION_NOT_LISTED })
})

test('a row at the same time of another programme does not stand in', () => {
  assert.deepEqual(reservationAgain([row({ id: '0x2', event_id: 101 })], row()), { why: RESERVATION_NOT_LISTED })
})

test('a reservation an app made is not looked for once its id has gone', () => {
  const held = row({ creator: '2200', created_by_app: true })
  assert.deepEqual(reservationAgain([row({ id: '0x2', creator: '2200', created_by_app: true })], held), { why: RESERVATION_NOT_LISTED })
})
