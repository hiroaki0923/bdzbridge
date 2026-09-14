<script>
  import { loadPref, savePref } from '../prefs.js'
  import { api, fmtDateTime, repeatOptions } from '../api.js'
  import { app, loadReservations, toast } from '../store.svelte.js'
  let confirmTarget = $state(null)
  let busy = $state(false)
  let error = $state('')
  let rules = $state([])
  let autoLog = $state([])
  let autoOpen = $state(false)
  let autoBusy = $state(false)
  async function loadAuto() {
    try { [rules, autoLog] = await Promise.all([api('/rules'), api('/rules/log', { query: { limit: 10 } })]) } catch { /* older server */ }
  }
  $effect(() => { loadAuto() })
  async function toggleRule(r) { await api(`/rules/${r.id}`, { method: 'PATCH', body: { enabled: !r.enabled } }); await loadAuto() }
  async function deleteRule(r) { await api(`/rules/${r.id}`, { method: 'DELETE' }); await loadAuto(); toast('自動予約を削除しました') }
  async function runRules() {
    autoBusy = true; error = ''
    try {
      const res = await api('/rules/run', { method: 'POST' })
      toast(`自動予約: ${res.reserved} 件予約${res.conflicts ? '、重複 ' + res.conflicts + ' 件' : ''}${res.errors ? '、失敗 ' + res.errors + ' 件' : ''}`)
      await Promise.all([loadReservations(), loadAuto()])
    } catch (e) { error = e.message } finally { autoBusy = false }
  }
  const statusLabel = { reserved: '予約', conflict: '重複', error: '失敗' }
  const SORTS = [['time', '日時'], ['genre', 'ジャンル'], ['channel', '局']]
  let sort = $state(loadPref('resSort', null) || 'time')
  $effect(() => { savePref('resSort', sort) })
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
<div class="card">
  <button class="row" style="width:100%; justify-content: space-between" onclick={() => (autoOpen = !autoOpen)}>
    <span class="title">自動予約 <span class="muted">{rules.length} 件のキーワード</span></span><span class="muted">{autoOpen ? '閉じる' : '開く'}</span>
  </button>
  {#if autoOpen}
    {#if rules.length === 0}<p class="muted">検索タブでキーワードを検索して「自動予約」を押すと登録できます。番組表の更新のたびに該当番組を予約して通知します。</p>{/if}
    {#each rules as r (r.id)}
      <div class="field">
        <span><b>{r.query}</b><br /><span class="muted">{r.service_name ?? (r.broadcasting ? app.defaults?.broadcastings?.[r.broadcasting] ?? r.broadcasting : '全放送')} · {r.quality} · {r.title_only ? 'タイトル' : 'タイトル+説明'}</span></span>
        <span class="row"><button class="chip" class:on={r.enabled} onclick={() => toggleRule(r)}>{r.enabled ? '有効' : '停止中'}</button><button class="chip" onclick={() => deleteRule(r)}>削除</button></span>
      </div>
    {/each}
    {#if rules.length}<button class="btn ghost" disabled={autoBusy} onclick={runRules}>{autoBusy ? '実行中…' : '今すぐ実行'}</button>{/if}
    {#if autoLog.length}
      <p class="muted" style="margin:10px 0 4px">最近の結果</p>
      {#each autoLog as l (l.id)}<div class="muted">{fmtDateTime(l.start)} {l.title} — {statusLabel[l.status] ?? l.status}{l.message ? '（' + l.message + '）' : ''}</div>{/each}
    {/if}
  {/if}
</div>
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
        <select bind:value={repeat}>{#each repeatOptions(app.defaults?.repeats, confirmTarget.start) as [k, v] (k)}<option value={k}>{v}</option>{/each}</select></label>
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
