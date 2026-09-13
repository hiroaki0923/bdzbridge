<script>
  import { api, fmtDateTime, fmtTime, findReservation } from '../api.js'
  import { app, loadReservations, toast } from '../store.svelte.js'
  let { program, onclose } = $props()
  let existing = $derived(findReservation(app.resIdx, program))
  let quality = $state(app.defaults?.quality ?? 'LSR')
  let repeat = $state(app.defaults?.repeat ?? 'none')
  let busy = $state(false)
  let error = $state('')
  let conflicts = $state([])
  let showExt = $state(false)

  async function reserve(force = false) {
    busy = true; error = ''; conflicts = []
    try {
      await api('/reservations', { method: 'POST', body: { broadcasting: program.broadcasting, service_id: program.service_id, event_id: program.event_id, quality, repeat, force } })
      await loadReservations()
      toast('予約しました')
      onclose()
    } catch (e) {
      if (e.status === 409) { conflicts = e.body?.detail?.conflicts ?? []; error = '同じ時間帯の予約と重なります' }
      else error = e.message
    } finally { busy = false }
  }
  async function remove() {
    busy = true; error = ''
    try { await api(`/reservations/${existing.id}`, { method: 'DELETE' }); await loadReservations(); toast('予約を削除しました'); onclose() }
    catch (e) { error = e.message } finally { busy = false }
  }
  let editing = $state(false)
  function startEdit() { quality = existing.quality; repeat = existing.repeat; editing = true }
  async function saveEdit() {
    busy = true; error = ''
    try { await api(`/reservations/${existing.id}`, { method: 'PATCH', body: { quality, repeat } }); await loadReservations(); toast('予約を変更しました'); editing = false }
    catch (e) { error = e.message } finally { busy = false }
  }
</script>

<div class="sheet-bg" onclick={onclose} role="presentation"></div>
<div class="sheet">
  <p class="muted">{program.service_name} · {fmtDateTime(program.start)}–{fmtTime(program.end)} · {Math.round(program.duration_sec / 60)}分{program.genres[0] ? ' · ' + program.genres[0].label : ''}</p>
  <h2>{program.title}</h2>
  {#if program.description}<p>{program.description}</p>{/if}
  {#if program.extended}
    {#if showExt}<p class="muted" style="white-space: pre-wrap">{program.extended}</p>{:else}<button class="chip" onclick={() => (showExt = true)}>番組内容を表示</button>{/if}
  {/if}

  {#if existing}
    <div class="card" style="margin-top:14px">
      <div><span class="mark">{existing.recording ? '録画中' : '予約済み'}</span>{existing.repeat_label} · {existing.quality_label}{existing.tracks_program ? ' · 番組追従' : ' · 時刻指定'}</div>
    </div>
    {#if editing}
      <label class="field"><span>録画モード</span>
        <select bind:value={quality}>{#each Object.entries(app.defaults?.qualities ?? {}) as [k, v]}<option value={k}>{v}</option>{/each}</select></label>
      <label class="field"><span>毎回録画</span>
        <select bind:value={repeat}>{#each Object.entries(app.defaults?.repeats ?? {}) as [k, v]}<option value={k}>{v}</option>{/each}</select></label>
      <button class="btn" disabled={busy} onclick={saveEdit}>{busy ? '送信中…' : '変更を保存'}</button>
      <button class="btn ghost" onclick={() => (editing = false)}>変更をやめる</button>
    {:else}
      <button class="btn ghost" disabled={busy} onclick={startEdit}>録画モード・毎回録画を変更</button>
      <button class="btn danger" disabled={busy} onclick={remove}>予約を削除</button>
    {/if}
  {:else}
    <div style="margin-top:12px">
      <label class="field"><span>録画モード</span>
        <select bind:value={quality}>{#each Object.entries(app.defaults?.qualities ?? {}) as [k, v]}<option value={k}>{v}</option>{/each}</select></label>
      <label class="field"><span>毎回録画</span>
        <select bind:value={repeat}>{#each Object.entries(app.defaults?.repeats ?? {}) as [k, v]}<option value={k}>{v}</option>{/each}</select></label>
    </div>
    {#if conflicts.length}
      <div class="card"><div class="muted">重なる予約</div>{#each conflicts as c}<div>{fmtDateTime(c.start)} {c.title}</div>{/each}</div>
      <button class="btn danger" disabled={busy} onclick={() => reserve(true)}>重複を承知で予約する</button>
    {:else}
      <button class="btn" disabled={busy} onclick={() => reserve(false)}>{busy ? '送信中…' : '録画予約する'}</button>
    {/if}
  {/if}
  {#if error}<p class="error">{error}</p>{/if}
  <button class="btn ghost" onclick={onclose}>閉じる</button>
</div>
