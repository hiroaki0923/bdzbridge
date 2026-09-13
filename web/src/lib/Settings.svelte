<script>
  import { api, setToken, fmtBytes } from '../api.js'
  import { app, loadStatus, loadReservations, toast } from '../store.svelte.js'
  let { onreselect, onlogout } = $props()
  let busy = $state(false)
  let error = $state('')
  async function run(label, fn) {
    busy = true; error = ''
    try { await fn(); await loadStatus(); toast(label) } catch (e) { error = e.message } finally { busy = false }
  }
  let notify = $state(null)
  $effect(() => { api('/notify').then((n) => (notify = n)).catch(() => (notify = null)) })
  const epg = $derived(app.status?.epg ?? {})
  const names = { td: '地デジ', bs: 'BS', cs: 'CS', bs4k: 'BS4K', cs4k: 'CS4K' }
</script>

<h1>設定</h1>
<div class="card">
  <div class="title">{app.status?.friendly_name ?? '—'}</div>
  <div class="muted">{app.status?.product} · {app.status?.host} · ファーム {app.status?.firmware ?? '?'} · 電源 {app.status?.power ?? '?'}</div>
  {#if app.status?.storage}<div class="muted">HDD 残り {fmtBytes(app.status.storage.free_bytes)} / {fmtBytes(app.status.storage.total_bytes)}（{(100 * app.status.storage.free_bytes / app.status.storage.total_bytes).toFixed(1)}%）</div>{/if}
  <div class="muted" style="margin-top:6px">
    {#if app.status?.epg_capable === false}<span class="error">この機種は番組表を提供していません（EPG_CAP 00）。</span><br />{/if}
    {#each Object.entries(epg) as [k, v]}{#if typeof v === 'object' && v}{names[k] ?? k}: {v.channels}局/{v.programs}番組{v.refreshed ? '（' + v.refreshed.slice(5, 16).replace('T', ' ') + '）' : ''}<br />{/if}{/each}
    {#if epg.last_error}<span class="error">取得エラー: {epg.last_error}</span>{/if}
  </div>
  <button class="btn ghost" disabled={busy} onclick={() => run('番組表を更新しました', () => api('/epg/refresh', { method: 'POST' }))}>番組表を今すぐ更新</button>
  {#if app.status?.reachable === false}
    <p class="error">レコーダーがネットワークに応答していません。{app.status.mac ? 'Wake-on-LAN で起動を試せます。' : 'MAC アドレスが分からないので、本体の電源を入れてください。'}</p>
    {#if app.status.mac}<button class="btn" disabled={busy} onclick={() => run('起動しました', () => api('/recorder/wake', { method: 'POST' }))}>レコーダーを起動する（Wake-on-LAN）</button>{/if}
  {:else}
    <button class="btn ghost" disabled={busy} onclick={() => run('電源を入れました', () => api('/recorder/power', { method: 'POST' }))}>レコーダーの電源を入れる</button>
  {/if}
  <button class="btn ghost" disabled={busy} onclick={() => run('予約を再読込しました', loadReservations)}>予約一覧を再読込</button>
  {#if error}<p class="error">{error}</p>{/if}
</div>
<div class="card">
  <div class="title">通知</div>
  <div class="muted">
    {#if notify === null}—
    {:else if !notify.configured}未設定です。サーバーの .env に BDZBRIDGE_SMTP_*（メール）か BDZBRIDGE_NOTIFY_WEBHOOK を書くと、自動予約の結果が届きます。
    {:else}メール: {notify.email ? notify.to : 'なし'} · Webhook: {notify.webhook ? 'あり' : 'なし'}{/if}
  </div>
  {#if notify?.configured}<button class="btn ghost" disabled={busy} onclick={() => run('テスト通知を送りました', () => api('/notify/test', { method: 'POST' }))}>テスト通知を送る</button>{/if}
</div>
<div class="card">
  <button class="btn ghost" onclick={onreselect}>レコーダーを選び直す</button>
  <button class="btn ghost" onclick={() => { setToken(''); onlogout() }}>トークンを変更（サインアウト）</button>
</div>
<p class="muted" style="text-align:center">bdzbridge web 0.1</p>
