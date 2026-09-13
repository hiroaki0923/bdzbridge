<script>
  import { api, fmtDateTime } from '../api.js'
  import { app, loadReservations, toast } from '../store.svelte.js'
  let confirmTarget = $state(null)
  let busy = $state(false)
  let error = $state('')
  const SORTS = [['time', '日時'], ['genre', 'ジャンル'], ['channel', '局']]
  let sort = $state(localStorage.getItem('recbridge.resSort') || 'time')
  $effect(() => { localStorage.setItem('recbridge.resSort', sort) })
  const byStart = (a, b) => new Date(a.start) - new Date(b.start)
  // [{ key, label, items }] in display order; a single unlabeled group for the plain time order
  const groups = $derived.by(() => {
    const list = [...app.reservations].sort(byStart)
    if (sort === 'time') return [{ key: 'all', label: '', items: list }]
    const keyOf = sort === 'genre'
      ? (r) => [r.genres[0]?.level1 ?? 99, r.genres[0]?.label ?? 'ジャンル不明']
      : (r) => [r.service_name ?? r.broadcasting, r.service_name ?? r.broadcasting]
    const m = new Map()
    for (const r of list) {
      const [k, label] = keyOf(r)
      if (!m.has(k)) m.set(k, { key: String(k), label, items: [] })
      m.get(k).items.push(r)
    }
    return [...m.entries()].sort(([a], [b]) => (typeof a === 'number' ? a - b : String(a).localeCompare(String(b), 'ja'))).map(([, g]) => g)
  })

  async function refresh() { busy = true; try { await loadReservations() } finally { busy = false } }
  let editing = $state(false)
  let quality = $state('LSR')
  let repeat = $state('none')
  function startEdit() { quality = confirmTarget.quality; repeat = confirmTarget.repeat; editing = true }
  async function save() {
    busy = true; error = ''
    try { await api(`/reservations/${confirmTarget.id}`, { method: 'PATCH', body: { quality, repeat } }); await loadReservations(); toast('予約を変更しました'); editing = false; confirmTarget = null }
    catch (e) { error = e.message } finally { busy = false }
  }
  async function remove() {
    busy = true; error = ''
    try { await api(`/reservations/${confirmTarget.id}`, { method: 'DELETE' }); await loadReservations(); toast('予約を削除しました'); confirmTarget = null }
    catch (e) { error = e.message } finally { busy = false }
  }
</script>

<div class="row" style="justify-content: space-between"><h1>予約 <span class="muted">{app.reservations.length} 件</span></h1><button class="chip" onclick={refresh}>{busy ? '…' : '更新'}</button></div>
<div class="seg">{#each SORTS as [id, label]}<button class:on={sort === id} onclick={() => (sort = id)}>{label}</button>{/each}</div>
{#if app.reservations.length === 0}<div class="list"><p class="empty">予約はありません</p></div>{/if}
{#each groups as g (g.key)}
  {#if g.label}<div class="group-head">{g.label} <span class="muted">{g.items.length} 件</span></div>{/if}
  <div class="list">
    {#each g.items as r (r.id)}
      <button class="item" onclick={() => (confirmTarget = r)}>
        <span class="time">{fmtDateTime(r.start).replace(' ', '\n')}</span>
        <span>
          {#if r.recording}<span class="mark">録画中</span>{/if}{#if r.conflict}<span class="mark" style="background:#ff9500">重複</span>{/if}<span class="title">{r.title}</span>
          <div class="sub">{r.service_name ?? r.broadcasting}{r.genres[0] ? ' · ' + r.genres[0].label : ''} · {r.repeat_label} · {r.quality_label} · {Math.round(r.duration_sec / 60)}分{r.tracks_program ? ' · 番組追従' : ' · 時刻指定'}</div>
        </span>
      </button>
    {/each}
  </div>
{/each}

{#if confirmTarget}
  <div class="sheet-bg" onclick={() => { confirmTarget = null; editing = false }} role="presentation"></div>
  <div class="sheet">
    <h2>{confirmTarget.title}</h2>
    <p class="muted">{fmtDateTime(confirmTarget.start)} · {confirmTarget.service_name ?? ''} · {confirmTarget.repeat_label} · {confirmTarget.quality_label}</p>
    {#if editing}
      <label class="field"><span>録画モード</span>
        <select bind:value={quality}>{#each Object.entries(app.defaults?.qualities ?? {}) as [k, v]}<option value={k}>{v}</option>{/each}</select></label>
      <label class="field"><span>毎回録画</span>
        <select bind:value={repeat}>{#each Object.entries(app.defaults?.repeats ?? {}) as [k, v]}<option value={k}>{v}</option>{/each}</select></label>
      <button class="btn" disabled={busy} onclick={save}>{busy ? '送信中…' : '変更を保存'}</button>
      <button class="btn ghost" onclick={() => (editing = false)}>変更をやめる</button>
    {:else}
      <button class="btn ghost" disabled={busy} onclick={startEdit}>録画モード・毎回録画を変更</button>
      <button class="btn danger" disabled={busy} onclick={remove}>この予約を削除</button>
      <button class="btn ghost" onclick={() => (confirmTarget = null)}>閉じる</button>
    {/if}
    {#if error}<p class="error">{error}</p>{/if}
  </div>
{/if}
