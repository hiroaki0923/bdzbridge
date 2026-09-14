<script>
  // Hide channels and change their order for one broadcasting type. Every change is saved right away.
  import { api } from '../api.js'
  import { toast } from '../store.svelte.js'
  let { bt, label, onclose, onchange } = $props()
  let channels = $state([])
  let busy = $state(false)
  let error = $state('')

  async function load() {
    try { channels = await api('/channels', { query: { broadcasting: bt, include_hidden: true } }) } catch (e) { error = e.message }
  }
  $effect(() => { bt; load() })
  async function save(prefs) {
    busy = true; error = ''
    try { channels = await api(`/channels/${bt}/prefs`, { method: 'PUT', body: prefs }); onchange?.() }
    catch (e) { error = e.message } finally { busy = false }
  }
  const toggleHidden = (c) => save({ hidden: channels.filter((x) => (x.service_id === c.service_id ? !x.hidden : x.hidden)).map((x) => x.service_id) })
  function move(c, delta) {
    const ids = channels.map((x) => x.service_id)
    const i = ids.indexOf(c.service_id), j = i + delta
    if (j < 0 || j >= ids.length) return
    ;[ids[i], ids[j]] = [ids[j], ids[i]]
    save({ order: ids })
  }
  const reset = () => save({ order: [], hidden: [] })
</script>

<div class="sheet-bg" onclick={onclose} role="presentation"></div>
<div class="sheet">
  <div class="row" style="justify-content: space-between"><h2>{label} の局の表示</h2><button class="chip" onclick={onclose}>閉じる</button></div>
  <p class="muted">非表示にした局は番組表と検索に出なくなります。▲▼ で並び順を変えられます。</p>
  {#if error}<p class="error">{error}</p>{/if}
  <div class="list">
    {#each channels as c (c.service_id)}
      <div class="item pref" class:off={c.hidden}>
        <span class="row" style="gap:6px">{#if c.logo}<img class="logo" src={c.logo} alt="" />{/if}<span class="title">{c.name}</span></span>
        <span class="row" style="gap:6px; justify-content:flex-end">
          <button class="chip" disabled={busy} onclick={() => move(c, -1)} aria-label="上へ">▲</button>
          <button class="chip" disabled={busy} onclick={() => move(c, 1)} aria-label="下へ">▼</button>
          <button class="chip" class:on={!c.hidden} disabled={busy} onclick={() => toggleHidden(c)}>{c.hidden ? '非表示' : '表示'}</button>
        </span>
      </div>
    {/each}
  </div>
  <button class="btn ghost" disabled={busy} onclick={reset}>レコーダーの順に戻す（すべて表示）</button>
</div>

<style>
  .pref { grid-template-columns: 1fr auto; align-items: center; }
  .pref.off .title { color: var(--muted); text-decoration: line-through; }
  .logo { height: 18px; width: 32px; object-fit: contain; border-radius: 3px; background: #fff; }
</style>
