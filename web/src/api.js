// Thin client for the recbridge JSON API. Same origin in production; Vite proxies /api in dev.
const TOKEN_KEY = 'recbridge.token'

export function getToken() {
  return localStorage.getItem(TOKEN_KEY) || ''
}
export function setToken(t) {
  localStorage.setItem(TOKEN_KEY, t)
}

export class ApiError extends Error {
  constructor(status, body) {
    super(typeof body === 'string' ? body : body?.detail?.message || body?.detail || `HTTP ${status}`)
    this.status = status
    this.body = body
  }
}

export async function api(path, { method = 'GET', body, query } = {}) {
  const url = new URL('/api/v1' + path, location.origin)
  if (query) for (const [k, v] of Object.entries(query)) if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, v)
  const res = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${getToken()}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  })
  if (res.status === 204) return null
  const text = await res.text()
  let data = text
  try { data = JSON.parse(text) } catch { /* plain text */ }
  if (!res.ok) throw new ApiError(res.status, data)
  return data
}

// Reservation lookup helpers shared by the guide and the search view.
export function reservationKey(bt, serviceId, eventId) {
  return `${bt}:${serviceId}:${eventId}`
}
export function timeKey(bt, serviceId, startIso) {
  return `${bt}:${serviceId}:${new Date(startIso).getTime()}`
}
export function indexReservations(list) {
  const byEvent = new Map()
  const byTime = new Map()
  for (const r of list) {
    if (r.event_id != null) byEvent.set(reservationKey(r.broadcasting, r.service_id, r.event_id), r)
    byTime.set(timeKey(r.broadcasting, r.service_id, r.start), r)
  }
  return { byEvent, byTime, list }
}
export function findReservation(idx, p) {
  if (!idx) return null
  return idx.byEvent.get(reservationKey(p.broadcasting, p.service_id, p.event_id))
    || idx.byTime.get(timeKey(p.broadcasting, p.service_id, p.start)) || null
}

export const fmtTime = (iso) => new Date(iso).toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit', hour12: false })
export const fmtDate = (iso) => new Date(iso).toLocaleDateString('ja-JP', { month: 'numeric', day: 'numeric', weekday: 'short' })
export const fmtDateTime = (iso) => `${fmtDate(iso)} ${fmtTime(iso)}`
export const fmtBytes = (b) => (b >= 1e12 ? (b / 1e12).toFixed(2) + ' TB' : b >= 1e9 ? (b / 1e9).toFixed(1) + ' GB' : Math.round(b / 1e6) + ' MB')

// TV days run 04:00-04:00 JST. Returns YYYY-MM-DD for "today" in that sense, plus the next 7 days.
export function tvDays() {
  const now = new Date()
  const shifted = new Date(now.getTime() - 4 * 3600 * 1000)
  const days = []
  for (let i = 0; i < 8; i++) {
    const d = new Date(shifted.getFullYear(), shifted.getMonth(), shifted.getDate() + i)
    const iso = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
    days.push({ iso, label: d.toLocaleDateString('ja-JP', { month: 'numeric', day: 'numeric', weekday: 'short' }), today: i === 0 })
  }
  return days
}
