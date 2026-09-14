<script>
  // Confirmation for a destructive action; while the job runs it shows progress and offers 中止.
  let { title, lines = [], confirmLabel, busy = false, progress = null, progressLabel = '削除中', onconfirm, oncancel, onclose } = $props()
</script>

<div class="modal-bg" onclick={onclose} role="presentation"></div>
<div class="modal" role="dialog" aria-modal="true">
  <div class="title">{title}</div>
  {#each lines as l, i (i)}<p class="muted">{l}</p>{/each}
  {#if progress}
    <div class="bar"><div class="fill" style="width: {(100 * progress.done) / Math.max(1, progress.total)}%"></div></div>
    <p class="muted" style="text-align:center">{progressLabel} {progress.done} / {progress.total}</p>
    <button class="btn ghost" disabled={progress.cancelled} onclick={oncancel}>{progress.cancelled ? '中止します…' : '中止（以降は処理しない）'}</button>
  {:else}
    <button class="btn danger" disabled={busy} onclick={onconfirm}>{busy ? '処理中…' : confirmLabel}</button>
    <button class="btn ghost" disabled={busy} onclick={onclose}>やめる</button>
  {/if}
</div>
