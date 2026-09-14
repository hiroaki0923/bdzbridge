<script>
  import { tick } from 'svelte'
  import { fmtTime, fmtDate, findReservation } from '../api.js'
  import { app } from '../store.svelte.js'
  // scrollToNow: after a load, bring the first programme that has not ended to the top (today's guide)
  let { programs, showDate = false, showChannel = false, scrollToNow = false } = $props()
  const now = Date.now()
  const onAir = (p) => new Date(p.start).getTime() <= now && now < new Date(p.end).getTime()
  const ended = (p) => new Date(p.end).getTime() <= now
  let root = $state(null)
  $effect(() => {
    programs
    if (!scrollToNow) return
    tick().then(() => {
      const el = root?.querySelector('.item:not(.past)')
      if (el) window.scrollTo({ top: Math.max(0, el.getBoundingClientRect().top + window.scrollY - 150) })
    })
  })
</script>

<div class="list" bind:this={root}>
  {#if programs.length === 0}<p class="empty">番組がありません</p>{/if}
  {#each programs as p (p.broadcasting + p.service_id + p.event_id + p.start)}
    {@const r = findReservation(app.resIdx, p)}
    <button class="item" class:past={ended(p)} onclick={() => (app.sheet = p)}>
      <span class="time">{showDate ? fmtDate(p.start) + ' ' : ''}{fmtTime(p.start)}<br /><span class="muted">{Math.round(p.duration_sec / 60)}分</span></span>
      <span>
        {#if r}<span class="mark">{r.recording ? '録画中' : '予約'}</span>{:else if onAir(p)}<span class="mark now">放送中</span>{/if}<span class="title">{p.title}</span>
        <div class="sub">{showChannel ? p.service_name + ' · ' : ''}{p.genres[0]?.label ?? ''}{p.description ? ' · ' + p.description : ''}</div>
      </span>
    </button>
  {/each}
</div>
