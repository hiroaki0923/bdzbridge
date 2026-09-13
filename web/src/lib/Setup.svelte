<script>
  import { api, getToken, setToken } from '../api.js'
  let { mode, error = '', ondone } = $props()
  let token = $state(getToken())
  let busy = $state(false)
  let msg = $state('')
  $effect(() => { msg = error })
  let candidates = $state(null)

  async function saveToken() {
    setToken(token.trim())
    busy = true; msg = ''
    try { await api('/recorder'); ondone() } catch (e) { msg = e.status === 401 ? 'トークンが違います' : e.message } finally { busy = false }
  }
  async function discover() {
    busy = true; msg = ''; candidates = null
    try { candidates = await api('/recorders/discover') } catch (e) { msg = e.message } finally { busy = false }
  }
  async function select(host) {
    busy = true; msg = ''
    try { await api('/recorder', { method: 'PUT', body: { host } }); ondone() } catch (e) { msg = e.message } finally { busy = false }
  }
  $effect(() => { if (mode === 'recorder' && candidates === null && !busy) discover() })
</script>

<main>
  <h1>bdzbridge</h1>
  {#if mode === 'token'}
    <div class="card">
      <p class="muted">サーバーのアクセストークンを入力してください（BDZBRIDGE_API_TOKEN）。</p>
      <input class="search" type="password" placeholder="トークン" bind:value={token} onkeydown={(e) => e.key === 'Enter' && saveToken()} />
      <button class="btn" disabled={busy || !token.trim()} onclick={saveToken}>接続</button>
      {#if msg}<p class="error">{msg}</p>{/if}
    </div>
  {:else}
    <div class="card">
      <p class="muted">レコーダーが未設定です。LAN 内を探索して選んでください。</p>
      {#if busy && candidates === null}<p class="empty"><span class="spinner"></span>探索中（数秒かかります）</p>{/if}
      {#if candidates}
        {#if candidates.length === 0}<p class="empty">見つかりませんでした。レコーダーの電源とネットワーク接続を確認してください。</p>{/if}
        {#each candidates as c}
          <button class="item" onclick={() => select(c.host)}>
            <span class="time">📼</span>
            <span><span class="title">{c.friendly_name}</span><br /><span class="muted">{c.product} · {c.host} · {c.epg_capable ? '番組表対応' : '番組表非対応'}</span></span>
          </button>
        {/each}
      {/if}
      <button class="btn ghost" disabled={busy} onclick={discover}>もう一度探す</button>
      {#if msg}<p class="error">{msg}</p>{/if}
    </div>
  {/if}
</main>
