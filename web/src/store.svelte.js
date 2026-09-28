import { api, indexReservations } from './api.js'

export const app = $state({
  tab: 'guide',
  status: null,       // GET /recorder
  defaults: null,     // GET /defaults
  reservations: [],   // GET /reservations
  resIdx: null,
  sheet: null,        // program shown in the detail sheet
  toast: '',
})

export async function loadStatus() {
  app.status = await api('/recorder')
  return app.status
}
export async function loadDefaults() {
  app.defaults = await api('/defaults')
}
export async function loadReservations() {
  const list = await api('/reservations')
  app.reservations = list
  app.resIdx = indexReservations(list)
}
// Changes or deletes a reservation as the recorder holds it now: `send` gets that one and makes the request.
// The recorder renumbers the reservations its own automatic recording made, the whole block at once, whenever
// it works through the guide again (docs/xsrs-api.md). An id read a while ago can therefore be dead while the
// row on screen looks the same, and sending it answers 804 -- which reads as a broken change or delete rather
// than a stale row. So the list is read again first and the reservation found by its id, or else by its
// channel and start time, which no two reservations can share. Throws with a sentence for the reader when it
// has gone, or when the server still does not know it (renumbered again in between); the list is fresh then.
export async function actOnReservation(wanted, send) {
  await loadReservations()
  const start = new Date(wanted.start).getTime()
  const target = app.reservations.find((r) => r.id === wanted.id)
    ?? app.reservations.find((r) => r.broadcasting === wanted.broadcasting && r.service_id === wanted.service_id
      && new Date(r.start).getTime() === start)
  if (!target) throw new Error('この予約はレコーダーにもうありませんでした。一覧を取り直しました。')
  try {
    await send(target)
  } catch (e) {
    if (e.status !== 404) throw e
    await loadReservations()
    throw new Error('レコーダー側で予約が更新されていました。一覧を取り直したので、もう一度お試しください。')
  }
  await loadReservations()
}
let toastTimer
export function toast(msg) {
  app.toast = msg
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => (app.toast = ''), 2500)
}
