<script>
  import { loadPref, savePref } from '../prefs.js'
  // Time × channel grid for one TV day (04:00–04:00). Programs are absolutely positioned inside their channel column.
  // The time axis zooms (pinch, ctrl+wheel, or the +/- buttons); the labels stick to the visible part of long programs.
  import { tick, untrack } from 'svelte'
  import { fmtTime, findReservation } from '../api.js'
  import { app } from '../store.svelte.js'

  let { channels, programs, day } = $props()

  const COL = 132
  const GUTTER = 30
  const HEAD = 54
  const DAY_MIN = 24 * 60
  const MIN_PX = 1.5
  const MAX_PX = 8
  const HOURS = Array.from({ length: 24 }, (_, i) => (i + 4) % 24)
  // ARIB level-1 genre → accent colour
  const GENRE = { 0: '#8e8e93', 1: '#34c759', 2: '#ff9500', 3: '#ff2d55', 4: '#af52de', 5: '#ffcc00', 6: '#007aff', 7: '#5ac8fa', 8: '#30b0c7', 9: '#a2845e', 10: '#5856d6', 11: '#00c7be' }

  let pxMin = $state(Number(loadPref('gridPxMin', null)) || 3) // pixels per minute
  $effect(() => { savePref('gridPxMin', String(pxMin)) })

  const dayStart = $derived(new Date(`${day}T04:00:00+09:00`).getTime())
  const byService = $derived.by(() => {
    const m = new Map()
    for (const p of programs) {
      if (!m.has(p.service_id)) m.set(p.service_id, [])
      m.get(p.service_id).push(p)
    }
    return m
  })
  // channels without any program that day (sub-channels that only mirror their parent) are left out
  const cols = $derived(channels.filter((c) => byService.has(c.service_id)))
  const width = $derived(GUTTER + cols.length * COL)
  const nowMin = $derived((Date.now() - dayStart) / 60000)
  const showNow = $derived(nowMin >= 0 && nowMin < DAY_MIN)
  const onAir = (p) => showNow && new Date(p.start).getTime() <= Date.now() && Date.now() < new Date(p.end).getTime()

  function top(p) {
    return Math.max(0, (new Date(p.start).getTime() - dayStart) / 60000) * pxMin
  }
  function height(p) {
    const s = Math.max(new Date(p.start).getTime(), dayStart)
    const e = Math.min(new Date(p.end).getTime(), dayStart + DAY_MIN * 60000)
    return Math.max(10, ((e - s) / 60000) * pxMin - 2)
  }
  const color = (p) => GENRE[p.genres[0]?.level1] ?? 'var(--line)'

  let el = $state(null)
  let offsetTop = $state(0)
  $effect(() => {
    const measure = () => { if (el) offsetTop = el.getBoundingClientRect().top + window.scrollY }
    measure()
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  })
  // jump to "now" for today, to the top for other days (not on zoom changes)
  $effect(() => {
    day; cols.length
    if (el) el.scrollTop = untrack(() => (showNow ? Math.max(0, nowMin - 15) * pxMin : 0))
  })

  // --- vertical zoom: the minute under `anchorY` (px from the grid's top edge) stays where it is
  async function zoomTo(next, anchorY) {
    next = Math.min(MAX_PX, Math.max(MIN_PX, next))
    if (!el || next === pxMin) return
    const minute = (el.scrollTop + anchorY - HEAD) / pxMin
    pxMin = next
    await tick()
    el.scrollTop = HEAD + minute * next - anchorY
  }
  const zoomBy = (f) => zoomTo(pxMin * f, el ? el.clientHeight / 2 : 0)

  // pinch with two fingers, or ctrl+wheel on a desktop; the browser's own page zoom is suppressed on the grid
  $effect(() => {
    if (!el) return
    let startDist = 0, startPx = 0, midY = 0
    const dist = (t) => Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY)
    const onStart = (e) => {
      if (e.touches.length !== 2) return
      startDist = dist(e.touches); startPx = pxMin
      midY = (e.touches[0].clientY + e.touches[1].clientY) / 2 - el.getBoundingClientRect().top
    }
    const onMove = (e) => {
      if (e.touches.length !== 2 || !startDist) return
      e.preventDefault()
      zoomTo((startPx * dist(e.touches)) / startDist, midY)
    }
    const onEnd = (e) => { if (e.touches.length < 2) startDist = 0 }
    const onWheel = (e) => {
      if (!e.ctrlKey) return
      e.preventDefault()
      zoomTo(pxMin * Math.exp(-e.deltaY / 200), e.clientY - el.getBoundingClientRect().top)
    }
    const block = (e) => e.preventDefault()
    el.addEventListener('touchstart', onStart, { passive: true })
    el.addEventListener('touchmove', onMove, { passive: false })
    el.addEventListener('touchend', onEnd)
    el.addEventListener('touchcancel', onEnd)
    el.addEventListener('wheel', onWheel, { passive: false })
    el.addEventListener('gesturestart', block)
    el.addEventListener('gesturechange', block)
    return () => {
      el.removeEventListener('touchstart', onStart)
      el.removeEventListener('touchmove', onMove)
      el.removeEventListener('touchend', onEnd)
      el.removeEventListener('touchcancel', onEnd)
      el.removeEventListener('wheel', onWheel)
      el.removeEventListener('gesturestart', block)
      el.removeEventListener('gesturechange', block)
    }
  })
</script>

<div class="gridwrap">
  <div class="grid" bind:this={el} style="height: calc(100dvh - {offsetTop}px - 72px - env(safe-area-inset-bottom))">
    {#if cols.length === 0}
      <p class="empty">番組がありません</p>
    {:else}
      <div class="ghead" style="width: {width}px">
        <div class="corner" style="width: {GUTTER}px"></div>
        {#each cols as c (c.service_id)}
          <div class="gch" style="width: {COL}px">{#if c.logo}<img src={c.logo} alt="" />{/if}<span>{c.name}</span></div>
        {/each}
      </div>
      <div class="gbody" style="width: {width}px; height: {DAY_MIN * pxMin}px">
        <div class="gutter" style="width: {GUTTER}px">
          {#each HOURS as h, i}<div class="hour" style="top: {i * 60 * pxMin}px">{h}</div>{/each}
        </div>
        {#each cols as c (c.service_id)}
          <div class="gcol" style="width: {COL}px; background-size: 100% {60 * pxMin}px">
            {#each byService.get(c.service_id) as p (p.event_id + p.start)}
              {@const r = findReservation(app.resIdx, p)}
              <button class="prog" class:onair={onAir(p)} class:reserved={r} style="top: {top(p)}px; height: {height(p)}px; border-left-color: {color(p)}" onclick={() => (app.sheet = p)}>
                <span class="ptext"><span class="pt">{fmtTime(p.start)}</span>{#if r}<span class="mark">{r.recording ? '録画中' : '予約'}</span>{/if}{p.title}</span>
              </button>
            {/each}
          </div>
        {/each}
        {#if showNow}<div class="nowline" style="top: {nowMin * pxMin}px"></div>{/if}
      </div>
    {/if}
  </div>
  <div class="zoom">
    <button aria-label="時間軸を縮小" disabled={pxMin <= MIN_PX} onclick={() => zoomBy(1 / 1.4)}>−</button>
    <button aria-label="時間軸を拡大" disabled={pxMin >= MAX_PX} onclick={() => zoomBy(1.4)}>＋</button>
  </div>
</div>

<style>
  .gridwrap { position: relative; margin: 6px -12px 0; }
  .grid { overflow: auto; position: relative; background: var(--bg); -webkit-overflow-scrolling: touch; overscroll-behavior: contain; touch-action: pan-x pan-y; }
  .ghead { position: sticky; top: 0; z-index: 3; display: flex; height: 54px; background: var(--card); border-bottom: 1px solid var(--line); }
  .corner { position: sticky; left: 0; z-index: 4; flex: 0 0 auto; background: var(--card); }
  .gch { flex: 0 0 auto; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2px; padding: 2px 4px; border-left: 1px solid var(--line); font-size: 11px; overflow: hidden; }
  .gch img { height: 20px; width: 36px; object-fit: contain; background: #fff; border-radius: 3px; }
  .gch span { max-width: 100%; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
  .gbody { position: relative; display: flex; }
  .gutter { position: sticky; left: 0; z-index: 2; flex: 0 0 auto; background: var(--bg); border-right: 1px solid var(--line); }
  .hour { position: absolute; left: 0; right: 0; text-align: center; font-size: 11px; color: var(--muted); border-top: 1px solid var(--line); padding-top: 2px; }
  .gcol { position: relative; flex: 0 0 auto; border-left: 1px solid var(--line); background-image: linear-gradient(to bottom, var(--line) 0 1px, transparent 1px); }
  /* overflow: clip (not hidden) so the sticky label inside still tracks the grid's scrolling */
  /* a button centres its content vertically; a column flex box keeps the label at the top so sticky can take over */
  .prog { position: absolute; left: 1px; right: 1px; display: flex; flex-direction: column; justify-content: flex-start; overflow: clip; padding: 2px 4px 2px 5px; border-radius: 4px; border-left: 3px solid var(--line); background: var(--card); text-align: left; font-size: 12px; line-height: 1.3; }
  .prog.onair { box-shadow: inset 0 0 0 1.5px var(--accent); }
  .prog.reserved { background: color-mix(in srgb, var(--mark) 10%, var(--card)); }
  .ptext { position: sticky; top: 56px; display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 8; overflow: hidden; word-break: break-all; }
  .pt { color: var(--muted); font-size: 11px; margin-right: 4px; }
  .nowline { position: absolute; left: 0; right: 0; height: 2px; background: var(--danger); z-index: 1; pointer-events: none; }
  .zoom { position: absolute; right: 14px; bottom: 14px; display: flex; gap: 8px; z-index: 5; }
  .zoom button { width: 36px; height: 36px; border-radius: 50%; background: var(--card); color: var(--text); box-shadow: 0 1px 4px rgba(0,0,0,.3); font-size: 20px; line-height: 1; }
  .zoom button:disabled { opacity: .4; }
</style>
