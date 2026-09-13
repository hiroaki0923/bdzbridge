<script>
  import { api, setToken } from '../api.js'
  import { app, loadStatus, loadReservations, toast } from '../store.svelte.js'
  let { onreselect, onlogout } = $props()
  let busy = $state(false)
  let error = $state('')
  async function run(label, fn) {
    busy = true; error = ''
    try { await fn(); await loadStatus(); toast(label) } catch (e) { error = e.message } finally { busy = false }
  }
  const epg = $derived(app.status?.epg ?? {})
  const names = { td: '地デジ', bs: 'BS', cs: 'CS', bs4k: 'BS4K', cs4k: 'CS4K' }
</script>

<h1>設定</h1>
<div class="card">
  <div class="title">{app.status?.friendly_name ?? '—'}</div>
  <div class="muted">{app.status?.product} · {app.status?.host} · ファーム {app.status?.firmware ?? '?'} · 電源 {app.status?.power ?? '?'}</div>
  <div class="muted" style="margin-top:6px">
    {#if app.status?.epg_capable === false}<span class="error">この機種は番組表を提供していません（EPG_CAP 00）。</span><br />{/if}
    {#each Object.entries(epg) as [k, v]}{#if typeof v === 'object' && v}{names[k] ?? k}: {v.channels}局/{v.programs}番組{v.refreshed ? '（' + v.refreshed.slice(5, 16).replace('T', ' ') + '）' : ''}<br />{/if}{/each}
    {#if epg.last_error}<span class="error">取得エラー: {epg.last_error}</span>{/if}
  </div>
  <button class="btn ghost" disabled={busy} onclick={() => run('番組表を更新しました', () => api('/epg/refresh', { method: 'POST' }))}>番組表を今すぐ更新</button>
  <button class="btn ghost" disabled={busy} onclick={() => run('電源を入れました', () => api('/recorder/power', { method: 'POST' }))}>レコーダーの電源を入れる</button>
  <button class="btn ghost" disabled={busy} onclick={() => run('予約を再読込しました', loadReservations)}>予約一覧を再読込</button>
  {#if error}<p class="error">{error}</p>{/if}
</div>
<div class="card">
  <button class="btn ghost" onclick={onreselect}>レコーダーを選び直す</button>
  <button class="btn ghost" onclick={() => { setToken(''); onlogout() }}>トークンを変更（サインアウト）</button>
</div>
<p class="muted" style="text-align:center">recbridge web 0.1</p>
