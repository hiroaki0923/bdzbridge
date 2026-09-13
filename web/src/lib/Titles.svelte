<script>
  import { api, fmtDateTime, fmtDate, fmtTime } from '../api.js'
  import { app, toast } from '../store.svelte.js'
  const PAGE = 30
  let titles = $state([]) // newest first, 30 at a time (no filter)
  let all = $state(null) // every title; fetched once a genre is chosen
  let hasMore = $state(true)
  let shown = $state(PAGE) // rows shown while a genre is chosen
  let busy = $state(false)
  let error = $state('')
  let genre = $state(localStorage.getItem('recbridge.titleGenre') ?? '') // '' = all, else the ARIB level-1 code
  $effect(() => { localStorage.setItem('recbridge.titleGenre', genre) })
  let selected = $state(null)
  let detail = $state(null)
  let playback = $state(null)
  let playBusy = $state(false)

  async function loadPage(reset = true) {
    busy = true; error = ''
    try {
      const offset = reset ? 0 : titles.length
      const page = await api('/titles', { query: { limit: PAGE, offset } })
      titles = reset ? page : [...titles, ...page]
      hasMore = page.length === PAGE
    } catch (e) { error = e.message } finally { busy = false }
  }
  async function loadAll() {
    busy = true; error = ''
    try {
      let list = []
      for (let offset = 0; offset < 3000; offset += 100) {
        const page = await api('/titles', { query: { limit: 100, offset } })
        list = [...list, ...page]
        if (page.length < 100) break
      }
      all = list
    } catch (e) { error = e.message } finally { busy = false }
  }
  function refresh() { all = null; shown = PAGE; loadPage(true); if (genre) loadAll() }
  $effect(() => { loadPage(true); refreshPlayback() })
  $effect(() => { genre; shown = PAGE; if (genre && all === null) loadAll() })

  const genres = $derived(Object.entries(app.defaults?.genres ?? {}))
  const counts = $derived.by(() => {
    const m = {}
    for (const t of all ?? []) { const k = String(t.genres[0]?.level1 ?? ''); m[k] = (m[k] ?? 0) + 1 }
    return m
  })
  const filtered = $derived(genre ? (all ?? []).filter((t) => String(t.genres[0]?.level1 ?? '') === genre) : titles)
  const visible = $derived(genre ? filtered.slice(0, shown) : titles)
  const more = $derived(genre ? filtered.length > shown : hasMore && titles.length > 0)
  function loadMore() { if (genre) shown += PAGE; else loadPage(false) }

  async function open(t) {
    selected = t; detail = null
    try { detail = await api(`/titles/${t.id}`) } catch (e) { detail = { summary: '', details: [] } }
  }
  async function refreshPlayback() {
    try { playback = await api('/recorder/playback') } catch { playback = null }
  }
  async function playOnTv() {
    playBusy = true; error = ''
    try { playback = await api(`/titles/${selected.id}/play`, { method: 'POST' }); toast('テレビで再生を始めました'); selected = null }
    catch (e) { error = e.message; toast('再生できませんでした') } finally { playBusy = false }
  }
  async function control(operation) {
    playBusy = true
    try { playback = await api('/recorder/playback', { method: 'POST', body: { operation } }) } catch (e) { error = e.message } finally { playBusy = false }
  }
  const playingTitle = $derived(playback?.play === 'Playing' ? (all ?? titles).find((t) => t.id === playback.title_id) : null)
</script>

<div class="row" style="justify-content: space-between"><h1>録画</h1><button class="chip" onclick={refresh}>{busy ? '…' : '更新'}</button></div>
<div class="chips">
  <button class="chip" class:on={genre === ''} onclick={() => (genre = '')}>すべて</button>
  {#each genres as [k, label] (k)}
    {#if all === null || counts[k]}<button class="chip" class:on={genre === k} onclick={() => (genre = k)}>{label}{counts[k] ? ' ' + counts[k] : ''}</button>{/if}
  {/each}
</div>
{#if error}<p class="error">{error}</p>{/if}
{#if playback?.play === 'Playing'}
  <div class="card row" style="justify-content: space-between">
    <span><span class="mark now">テレビで再生中</span>{playingTitle?.title ?? playback.title_id}{playback.position_sec != null ? ' · ' + Math.floor(playback.position_sec / 60) + '分' : ''}</span>
    <span class="row"><button class="chip" disabled={playBusy} onclick={() => control('pause')}>一時停止</button><button class="chip" disabled={playBusy} onclick={() => control('stop')}>停止</button></span>
  </div>
{:else if playback?.play === 'Paused'}
  <div class="card row" style="justify-content: space-between">
    <span><span class="mark">一時停止中</span>{playingTitle?.title ?? playback.title_id}</span>
    <span class="row"><button class="chip" disabled={playBusy} onclick={() => control('resume')}>再開</button><button class="chip" disabled={playBusy} onclick={() => control('stop')}>停止</button></span>
  </div>
{/if}
<div class="list">
  {#if visible.length === 0}<p class="empty">{busy ? '読み込み中…' : '録画はありません'}</p>{/if}
  {#each visible as t (t.id)}
    <button class="item" onclick={() => open(t)}>
      <span class="time">{fmtDate(t.start)}<br /><span class="muted">{fmtTime(t.start)}</span></span>
      <span>
        {#if t.is_new}<span class="mark now">NEW</span>{/if}<span class="title">{t.title}</span>
        <div class="sub">{t.service_name ?? t.broadcasting}{t.genres[0] ? ' · ' + t.genres[0].label : ''} · {Math.round(t.duration_sec / 60)}分 · {t.quality}{t.size_mb ? ' · ' + (t.size_mb / 1024).toFixed(1) + 'GB' : ''}{t.protected ? ' · 保護' : ''}</div>
      </span>
    </button>
  {/each}
</div>
{#if more}<button class="btn ghost" disabled={busy} onclick={loadMore}>{busy ? '読み込み中…' : 'さらに読み込む'}</button>{/if}

{#if selected}
  <div class="sheet-bg" onclick={() => (selected = null)} role="presentation"></div>
  <div class="sheet">
    <p class="muted">{fmtDateTime(selected.start)} · {selected.service_name ?? ''}{selected.genres[0] ? ' · ' + selected.genres[0].label : ''} · {Math.round(selected.duration_sec / 60)}分 · {selected.quality}</p>
    <h2>{selected.title}</h2>
    {#if detail === null}<p class="muted"><span class="spinner"></span>番組内容を取得中</p>
    {:else}
      {#if detail.summary}<p>{detail.summary}</p>{/if}
      {#each detail.details as d}<p class="muted" style="white-space: pre-wrap">{d}</p>{/each}
    {/if}
    <button class="btn" disabled={playBusy} onclick={playOnTv}>{playBusy ? '電源を入れています…' : 'テレビで再生'}</button>
    <button class="btn ghost" onclick={() => (selected = null)}>閉じる</button>
  </div>
{/if}
