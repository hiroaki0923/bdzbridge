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
let toastTimer
export function toast(msg) {
  app.toast = msg
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => (app.toast = ''), 2500)
}
