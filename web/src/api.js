// Thin client for the bdzbridge JSON API. Same origin in production; Vite proxies /api in dev.
const TOKEN_KEY = 'bdzbridge.token'

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
export const RESERVATION_NOT_LISTED = 'この予約はレコーダーの予約一覧に見つかりませんでした。一覧を更新しました。'
export const RESERVATION_CHANGED = 'レコーダー側で予約が変更されていました。一覧を更新したので、もう一度お試しください。'

// The reservation held, in the list just read: `{ row }`, or `{ why }` when it is not there to write to. The rule
// is the app's, `[Reservation].target(of:)` in RecorderKit, and docs/porting.md says why: looking by channel and
// start alone changed or deleted the recorder's own reservation of the same programme in place of one the reader
// had deleted on the recorder. An id still on the programme it was on is that reservation; on another programme,
// nothing is to be sent to it. When the id has gone, only a row by the same maker of the same programme is it, and
// none for a reservation an app made, which the recorder has not been seen to renumber.
export function reservationAgain(list, wanted) {
  const sameStart = (r) => new Date(r.start).getTime() === new Date(wanted.start).getTime()
  const row = list.find((r) => r.id === wanted.id)
  if (row) {
    const same = row.broadcasting === wanted.broadcasting && row.service_id === wanted.service_id
      && row.event_id === wanted.event_id && (wanted.event_id != null || sameStart(row))
    return same ? { row } : { why: RESERVATION_CHANGED }
  }
  const again = !wanted.created_by_app && list.find((r) => r.broadcasting === wanted.broadcasting
    && r.service_id === wanted.service_id && sameStart(r) && r.creator === wanted.creator
    && r.event_id === wanted.event_id)
  return again ? { row: again } : { why: RESERVATION_NOT_LISTED }
}

// Why a reservation cannot be changed now, or '' when it can: the server refuses the same, and the sheets offer
// no change it would refuse (`RecorderDriver.whyNot(changing:)`).
export function whyNotChanging(r, now = Date.now()) {
  if (r.recording) return '録画中の予約は変更できません。'
  return new Date(r.end).getTime() <= now ? '放送が終わった予約は変更できません。' : ''
}

export const CONDITION_NOT_LISTED = 'この条件はレコーダーのおまかせ・まる録の一覧に見つかりませんでした。レコーダーで変更された場合も含みます。一覧を更新しました。'

// Whether a condition of the recorder's is in the list just read as the screen showed it, by its id and all it was
// read with. The recorder renumbers a condition its own screen edits, so an id read a while ago can be another's.
export function conditionStillListed(list, held) {
  return list.some((r) => JSON.stringify(r) === JSON.stringify(held))
}

// The disks a recording can go to, as [id, label]: the internal disk, a USB disk that takes recordings, and `own`, the
// disk a reservation is on, which is offered even when it cannot be had so that the sheet can say where it is.
export function diskLabel(destination, status) {
  return destination === 'USBHDD' ? status?.usb?.name || 'USB HDD' : 'HDD'
}
export function diskChoices(status, own) {
  const usb = status?.usb?.mounted && status.usb.total_bytes > 0
  return ['HDD', ...(usb || own === 'USBHDD' ? ['USBHDD'] : [])].map((d) => [d, diskLabel(d, status)])
}

export function findReservation(idx, p) {
  if (!idx) return null
  return idx.byEvent.get(reservationKey(p.broadcasting, p.service_id, p.event_id))
    || idx.byTime.get(timeKey(p.broadcasting, p.service_id, p.start)) || null
}

export const fmtTime = (iso) => new Date(iso).toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit', hour12: false })
export const fmtDate = (iso) => {
  const d = new Date(iso)
  const opts = { month: 'numeric', day: 'numeric', weekday: 'short' }
  if (d.getFullYear() !== new Date().getFullYear()) opts.year = 'numeric'
  return d.toLocaleDateString('ja-JP', opts)
}
export const fmtDateTime = (iso) => `${fmtDate(iso)} ${fmtTime(iso)}`
// From the first start to the last end, the end's date left out when it is the same day.
export const fmtSpan = (from, to) => `${fmtDateTime(from)} 〜 ${(fmtDate(from) === fmtDate(to) ? fmtTime : fmtDateTime)(to)}`

// Repeat options for a programme starting at `startIso`: the weekly ones are narrowed to its own weekday.
const WEEKDAY_KEYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'] // index = Date#getDay()
export function repeatOptions(repeats, startIso) {
  const own = startIso ? WEEKDAY_KEYS[new Date(startIso).getDay()] : null
  return Object.entries(repeats ?? {}).filter(([k]) => !WEEKDAY_KEYS.includes(k) || k === own)
}
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
