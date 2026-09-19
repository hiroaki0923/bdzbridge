<script>
  // Detail sheet for one recording: programme text, play on the TV, protect, delete.
  import { api, fmtDateTime } from '../../api.js'
  import { toast } from '../../store.svelte.js'
  import JobModal from './JobModal.svelte'
  let { title, onclose, onchanged, onplayback } = $props()
  let t = $state(title)
  $effect(() => { t = title })
  let detail = $state(null)
  let confirm = $state(false)
  let busy = $state(false)
  let flagBusy = $state(false)
  let playBusy = $state(false)
  let error = $state('')
  $effect(() => {
    const id = title.id
    detail = null
    api(`/titles/${id}`).then((d) => (detail = d)).catch(() => (detail = { summary: '', details: [] }))
  })
  async function remove() {
    busy = true; error = ''
    try {
      await api(`/titles/${t.id}`, { method: 'DELETE' })
      toast('削除しました'); confirm = false
      onchanged({ deleted: [t.id] }); onclose()
    } catch (e) { error = e.message; confirm = false } finally { busy = false }
  }
  async function setProtected(on) {
    flagBusy = true; error = ''
    try {
      await api(`/titles/${t.id}`, { method: 'PATCH', body: { protected: on } })
      t = { ...t, protected: on }
      toast(on ? '保護しました' : '保護を解除しました')
      onchanged({ protected: { [t.id]: on } })
    } catch (e) { error = e.message } finally { flagBusy = false }
  }
  async function play() {
    playBusy = true; error = ''
    try { onplayback(await api(`/titles/${t.id}/play`, { method: 'POST' })); toast('テレビで再生を始めました'); onclose() }
    catch (e) { error = e.message; toast('再生できませんでした') } finally { playBusy = false }
  }
</script>

<div class="sheet-bg" onclick={onclose} role="presentation" style="z-index: 22"></div>
<div class="sheet" style="z-index: 23">
  <p class="muted">{fmtDateTime(t.start)} · {t.service_name ?? ''}{t.genres[0] ? ' · ' + t.genres[0].label : ''} · {Math.round(t.duration_sec / 60)}分 · {t.quality}</p>
  <h2>{#if t.protected}<span class="lock" title="保護中">🔒</span>{/if}{#if t.recording}<span class="mark">録画中</span>{/if}{t.title}</h2>
  {#if detail === null}<p class="muted"><span class="spinner"></span>番組内容を取得中</p>
  {:else}
    {#if detail.summary}<p>{detail.summary}</p>{/if}
    {#each detail.details as d, i (i)}<p class="muted" style="white-space: pre-wrap">{d}</p>{/each}
  {/if}
  <button class="btn" disabled={playBusy} onclick={play}>{playBusy ? '電源を入れています…' : 'テレビで再生'}</button>
  <button class="btn ghost" disabled={flagBusy || t.recording} onclick={() => setProtected(!t.protected)}>{t.protected ? '保護を解除する' : '保護する（自動削除させない）'}</button>
  <!-- The recorder refuses a recording it is still writing to, with a bare HTTP 500 -->
  <button class="btn ghost danger-text" disabled={t.protected || t.recording} onclick={() => (confirm = true)}>{t.recording ? '録画中は削除できません' : t.protected ? '保護中は削除できません' : 'この録画を削除'}</button>
  {#if error}<p class="error">{error}</p>{/if}
  <button class="btn ghost" onclick={onclose}>閉じる</button>
</div>

{#if confirm}
  <JobModal title="この録画を削除しますか？" confirmLabel="削除する" {busy}
    lines={[t.title, `${fmtDateTime(t.start)} · ${t.service_name ?? ''} · ${Math.round(t.duration_sec / 60)}分${t.size_mb ? ' · ' + (t.size_mb / 1024).toFixed(1) + 'GB' : ''}`, 'レコーダーから消えます。元に戻せません。']}
    onconfirm={remove} onclose={() => (confirm = false)} />
{/if}
