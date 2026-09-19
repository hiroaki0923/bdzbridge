<script>
  // One programme group: its episodes with selection, bulk delete, and protection for the selection or the whole group.
  import { api } from '../../api.js'
  import { toast } from '../../store.svelte.js'
  import { cancelJob, outcome, runBulk } from '../../jobs.svelte.js'
  import PickRow from './PickRow.svelte'
  import JobModal from './JobModal.svelte'
  let { group, onopen, onclose, onchanged } = $props()
  let members = $state([])
  let picked = $state({})
  let confirm = $state(false)
  let busy = $state(false)
  let progress = $state(null)
  let error = $state('')
  $effect(() => {
    const key = group.key
    members = []; picked = {}
    api('/titles', { query: { series: key, limit: 500 } }).then((m) => (members = m)).catch((e) => (error = e.message))
  })
  const pickedIds = $derived(Object.keys(picked).filter((id) => picked[id]))
  const pickedSize = $derived(members.filter((m) => picked[m.id]).reduce((s, m) => s + (m.size_mb ?? 0), 0))
  const totalSize = $derived(members.reduce((s, m) => s + (m.size_mb ?? 0), 0))
  // Neither a protected recording nor one still being written to can be deleted, so neither is ticked
  function pickAll(on) { const p = {}; for (const m of members) if (!m.protected && !m.recording) p[m.id] = on; picked = p }
  const setProgress = (p) => (progress = p)
  async function cancel() {
    if (!progress?.id) return
    try { await cancelJob(progress.id); progress = { ...progress, cancelled: true } } catch (e) { error = e.message }
  }
  async function bulkDelete() {
    busy = true; error = ''
    try {
      const res = await runBulk('/titles/delete', { ids: pickedIds }, setProgress)
      // titles the recorder no longer lists (deleted elsewhere, or by an earlier job) are gone too
      const gone = new Set([...res.deleted, ...res.skipped.filter((x) => x.reason === 'not found').map((x) => x.id)])
      const other = res.skipped.filter((x) => x.reason !== 'not found')
      const missing = gone.size - res.deleted.length
      toast(`${outcome('削除', res.deleted.length, res)}${missing ? '（' + missing + ' 件は既に消えていました）' : ''}${other.length ? '（' + other.length + ' 件はスキップ）' : ''}`)
      confirm = false; picked = {}
      members = members.filter((m) => !gone.has(m.id))
      onchanged({ deleted: [...gone] })
      if (members.length === 0) onclose()
    } catch (e) { error = e.message; confirm = false } finally { busy = false; progress = null }
  }
  async function bulkProtect(on, ids = pickedIds) {
    busy = true; error = ''
    try {
      const res = await runBulk('/titles/protect', { ids, protected: on }, setProgress, 600)
      const changed = new Set(res.changed)
      for (const m of members) if (changed.has(m.id)) m.protected = on
      toast(outcome(on ? '保護' : '保護解除', res.changed.length, res))
      picked = {}
      onchanged({ protected: Object.fromEntries([...changed].map((id) => [id, on])) })
    } catch (e) { error = e.message } finally { busy = false; progress = null }
  }
  // a title changed from the detail sheet: keep the members in step
  export function apply(change) {
    if (change.deleted) members = members.filter((m) => !change.deleted.includes(m.id))
    if (change.protected) for (const m of members) if (m.id in change.protected) m.protected = change.protected[m.id]
  }
</script>

<div class="sheet-bg" onclick={onclose} role="presentation"></div>
<div class="sheet">
  <div class="row" style="justify-content: space-between"><h2>{group.name}</h2><button class="chip" onclick={onclose}>閉じる</button></div>
  <p class="muted">{members.length} 件 · 合計 {(totalSize / 1024).toFixed(1)}GB</p>
  <div class="row" style="margin-bottom: 6px; flex-wrap: wrap">
    <button class="chip" onclick={() => pickAll(true)}>保護以外をすべて選択</button><button class="chip" onclick={() => pickAll(false)}>選択解除</button>
    <span class="chip-gap" style="height: 20px"></span>
    <button class="chip" disabled={busy || !members.length} onclick={() => bulkProtect(true, members.map((m) => m.id))}>🔒 全部を保護</button>
    <button class="chip" disabled={busy || !members.length} onclick={() => bulkProtect(false, members.map((m) => m.id))}>全部の保護を解除</button>
  </div>
  {#if busy && progress && !confirm}<p class="muted"><span class="spinner"></span>処理中 {progress.done} / {progress.total} <button class="chip" disabled={progress.cancelled} onclick={cancel}>{progress.cancelled ? '中止します…' : '中止'}</button></p>{/if}
  <div class="list">
    {#if members.length === 0}<p class="empty"><span class="spinner"></span>読み込み中</p>{/if}
    {#each members as m (m.id)}
      <PickRow title={m} checked={!!picked[m.id]} onpick={(id, on) => (picked = { ...picked, [id]: on })} {onopen} />
    {/each}
  </div>
  {#if pickedIds.length}
    <button class="btn danger" disabled={busy} onclick={() => (confirm = true)}>選択した {pickedIds.length} 件を削除（{(pickedSize / 1024).toFixed(1)}GB）</button>
    <button class="btn ghost" disabled={busy} onclick={() => bulkProtect(true)}>選択した {pickedIds.length} 件を保護</button>
    <button class="btn ghost" disabled={busy} onclick={() => bulkProtect(false)}>選択した {pickedIds.length} 件の保護を解除</button>
  {/if}
  {#if error}<p class="error">{error}</p>{/if}
</div>

{#if confirm}
  <JobModal title="{pickedIds.length} 件を削除しますか？" confirmLabel="{pickedIds.length} 件を削除する"
    lines={[group.name, `合計 ${(pickedSize / 1024).toFixed(1)}GB。保護中のものは選べません。レコーダーから消えます。元に戻せません。`]}
    progress={busy ? progress : null} progressLabel="削除中" onconfirm={bulkDelete} oncancel={cancel} onclose={() => { if (!busy) confirm = false }} />
{/if}
