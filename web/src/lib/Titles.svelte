<script>
  import { api, fmtDateTime, fmtDate, fmtTime } from '../api.js'
  import { toast } from '../store.svelte.js'
  const PAGE = 30
  let titles = $state([])
  let hasMore = $state(true)
  let busy = $state(false)
  let error = $state('')
  let selected = $state(null)
  let detail = $state(null)
  let playback = $state(null)
  let playBusy = $state(false)

  async function load(reset = true) {
    busy = true; error = ''
    try {
      const offset = reset ? 0 : titles.length
      const page = await api('/titles', { query: { limit: PAGE, offset } })
      titles = reset ? page : [...titles, ...page]
      hasMore = page.length === PAGE
    } catch (e) { error = e.message } finally { busy = false }
  }
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
  $effect(() => { load(); refreshPlayback() })
  const playingTitle = $derived(playback?.play === 'Playing' ? titles.find((t) => t.id === playback.title_id) : null)
</script>

<div class="row" style="justify-content: space-between"><h1>録画</h1><button class="chip" onclick={() => load(true)}>{busy ? '…' : '更新'}</button></div>
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
  {#if titles.length === 0 && !busy}<p class="empty">録画はありません</p>{/if}
  {#each titles as t (t.id)}
    <button class="item" onclick={() => open(t)}>
      <span class="time">{fmtDate(t.start)}<br /><span class="muted">{fmtTime(t.start)}</span></span>
      <span>
        {#if t.is_new}<span class="mark now">NEW</span>{/if}<span class="title">{t.title}</span>
        <div class="sub">{t.service_name ?? t.broadcasting} · {Math.round(t.duration_sec / 60)}分 · {t.quality}{t.size_mb ? ' · ' + (t.size_mb / 1024).toFixed(1) + 'GB' : ''}{t.protected ? ' · 保護' : ''}</div>
      </span>
    </button>
  {/each}
</div>
{#if hasMore && titles.length > 0}<button class="btn ghost" disabled={busy} onclick={() => load(false)}>{busy ? '読み込み中…' : 'さらに読み込む'}</button>{/if}

{#if selected}
  <div class="sheet-bg" onclick={() => (selected = null)} role="presentation"></div>
  <div class="sheet">
    <p class="muted">{fmtDateTime(selected.start)} · {selected.service_name ?? ''} · {Math.round(selected.duration_sec / 60)}分 · {selected.quality}</p>
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

