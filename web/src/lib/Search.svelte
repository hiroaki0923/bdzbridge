<script>
  import { api } from '../api.js'
  import { loadReservations, toast } from '../store.svelte.js'
  import ProgramList from './ProgramList.svelte'
  let q = $state('')
  let ruleBusy = $state(false)
  async function addRule() {
    ruleBusy = true
    try {
      const rule = await api('/rules', { method: 'POST', body: { query: q.trim(), title_only: true }, query: { run: true } })
      const matches = await api(`/rules/${rule.id}/matches`)
      await loadReservations()
      toast(`「${rule.query}」を自動予約に登録しました（該当 ${matches.length} 件）`)
    } catch (e) { toast('登録できませんでした: ' + e.message) } finally { ruleBusy = false }
  }
  let programs = $state([])
  let busy = $state(false)
  let timer
  function schedule() {
    clearTimeout(timer)
    timer = setTimeout(run, 350)
  }
  async function run() {
    const term = q.trim()
    if (term.length < 2) { programs = []; return }
    busy = true
    try { programs = await api('/programs', { query: { q: term, limit: 300 } }) } finally { busy = false }
  }
</script>

<h1>検索</h1>
<input class="search" type="search" placeholder="番組名・説明で検索（8 日分）" bind:value={q} oninput={schedule} />
{#if busy}<p class="muted"><span class="spinner"></span>検索中</p>{/if}
{#if q.trim().length >= 2}
  <ProgramList {programs} showDate showChannel />
  <button class="btn ghost" disabled={ruleBusy} onclick={addRule}>{ruleBusy ? '登録中…' : `「${q.trim()}」をタイトルに含む番組を自動予約`}</button>
  <p class="muted" style="text-align:center">番組表の更新のたびに、まだ予約していない該当番組を予約して通知します。ルールは予約タブで管理できます。</p>
{:else}<p class="empty">2 文字以上で検索します</p>{/if}
