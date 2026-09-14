// Per-device UI preferences (tab, filters, zoom, ...) kept in localStorage under one prefix.
const PREFIX = 'bdzbridge.'

export function loadPref(key, fallback) {
  try {
    const v = localStorage.getItem(PREFIX + key)
    return v === null ? fallback : v
  } catch { return fallback }
}

export function savePref(key, value) {
  try { localStorage.setItem(PREFIX + key, String(value)) } catch { /* storage unavailable */ }
}
