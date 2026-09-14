<script>
  // Recordings that are copies of one broadcast, with the copy to keep marked and the rest pre-selected for deletion.
  import { untrack } from 'svelte'
  import { toast } from '../../store.svelte.js'
  import { cancelJob, outcome, runBulk, runJob } from '../../jobs.js'
  import PickRow from './PickRow.svelte'
  import JobModal from './JobModal.svelte'
  let { onopen, onchanged, refreshKey = 0 } = $props()
  let job = $state(null)
  let picked = $state({})
  let confirm = $state(false)
  let busy = $state(false)
  let progress = $state(null)
  let error = $state('')
  async function scan() {
    if (job && !job.finished) return
    error = ''; picked = {}
    try {
      const j = await runJob('/titles/duplicates', undefined, (x) => (job = x), 1000)
      const p = {}
      for (const s of j.result.sets ?? []) for (const id of s.suggest_delete) p[id] = true
      picked = p
    } catch (e) { error = e.message; job = { finished: true, cancelled: false, result: { sets: [] }, total: 0, done: 0 } }
  }
  $effect(() => { refreshKey; untrack(scan) })
  const sets = $derived(job?.finished ? (job.result.sets ?? []) : [])
  const ids = $derived(Object.keys(picked).filter((id) => picked[id]))
  const size = $derived(sets.flatMap((s) => s.items).filter((t) => picked[t.id]).reduce((a, t) => a + (t.size_mb ?? 0), 0))
  const setProgress = (p) => (progress = p)
  async function cancel() {
    if (!progress?.id) return
    try { await cancelJob(progress.id); progress = { ...progress, cancelled: true } } catch (e) { error = e.message }
  }
  async function remove() {
    busy = true; error = ''
    try {
      const res = await runBulk('/titles/delete', { ids }, setProgress)
      toast(`${outcome('削除', res.deleted.length, res)}${res.skipped.length ? '（' + res.skipped.length + ' 件はスキップ）' : ''}`)
      confirm = false
      onchanged({ deleted: res.deleted })
      job = null; scan()
    } catch (e) { error = e.message; confirm = false } finally { busy = false; progress = null }
  }
  // protection changed elsewhere: which copy to keep may change, so look again
  export function apply(change) { if (change.protected) { job = null; scan() } }
</script>

{#if error}<p class="error">{error}</p>{/if}
{#if !job || !job.finished}
  <div class="card">
    <p class="muted" style="margin:0 0 6px"><span class="spinner"></span>重複を調べています{#if job?.total} {job.done} / {job.total}（番組内容を照合中）{/if}</p>
    {#if job?.total}<div class="bar"><div class="fill accent" style="width: {(100 * job.done) / job.total}%"></div></div>{/if}
    <p class="muted">同じタイトルで同じ長さの録画について、レコーダーに番組内容を問い合わせて突き合わせます。初回は時間がかかります。</p>
    {#if job?.id && !job.cancelled}<button class="btn ghost" onclick={() => cancelJob(job.id)}>中止</button>{/if}
  </div>
{:else}
  <p class="muted">{#if job.cancelled}中止しました。「更新」でやり直せます。{:else}{sets.length} 組の重複{sets.length ? '。チェックが付いているのが削除候補で、先に放送された方（保護中や視聴途中のものがあればそちら）を残します。' : 'はありません。'}{/if}</p>
  {#each sets as s, i (i)}
    <div class="card">
      <div class="title">{s.title}</div>
      <div class="muted">{s.items.length} 本 · 合計 {(s.size_mb / 1024).toFixed(1)}GB · {s.confidence === 'high' ? '番組内容も同じ' : 'タイトルと長さが同じ（内容は未確認）'}</div>
      <div class="list" style="margin-top:8px">
        {#each s.items as t (t.id)}
          <PickRow title={t} checked={!!picked[t.id]} onpick={(id, on) => (picked = { ...picked, [id]: on })} {onopen}
            badge={(t.id === s.keep ? '残す · ' : '候補 · ') + s.reasons[t.id]} badgeClass={t.id === s.keep ? 'now' : 'dim'} />
        {/each}
      </div>
    </div>
  {/each}
  {#if ids.length}<button class="btn danger" disabled={busy} onclick={() => (confirm = true)}>選択した {ids.length} 件を削除（{(size / 1024).toFixed(1)}GB）</button>{/if}
{/if}

{#if confirm}
  <JobModal title="重複した {ids.length} 件を削除しますか？" confirmLabel="{ids.length} 件を削除する"
    lines={[`合計 ${(size / 1024).toFixed(1)}GB。それぞれの組で「残す」と付いた方は残ります。レコーダーから消えます。元に戻せません。`]}
    progress={busy ? progress : null} progressLabel="削除中" onconfirm={remove} oncancel={cancel} onclose={() => { if (!busy) confirm = false }} />
{/if}
