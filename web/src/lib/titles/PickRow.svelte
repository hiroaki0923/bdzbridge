<script>
  // A recorded title with a checkbox (bulk selection). With `badge` the badge replaces the name (the name is in the card above).
  import { fmtDateTime } from '../../api.js'
  let { title: t, checked = false, onpick, onopen, badge = null, badgeClass = '' } = $props()
  const facts = $derived(
    `${fmtDateTime(t.start)} · ${t.service_name ?? t.broadcasting} · ${Math.round(t.duration_sec / 60)}分 · ${t.quality}` +
    `${t.size_mb ? ' · ' + (t.size_mb / 1024).toFixed(1) + 'GB' : ''}` +
    `${t.watch_state === 'partway' ? ' · 途中' : t.watch_state === 'watched' ? ' · 視聴済み' : ' · 未視聴'}`
  )
</script>

<div class="item pick" class:on={checked}>
  <!-- the recorder refuses to delete a protected recording or one it is still writing to -->
  <label class="check"><input type="checkbox" disabled={t.protected || t.recording} {checked} onchange={(e) => onpick(t.id, e.target.checked)} /></label>
  <button class="pickbody" onclick={() => onopen(t)}>
    {#if t.protected}<span class="lock">🔒</span>{/if}
    {#if badge}<span class="mark {badgeClass}">{badge}</span>{:else}{#if t.is_new}<span class="mark now">NEW</span>{/if}<span class="title">{t.title}</span>{/if}
    <div class="sub">{facts}</div>
  </button>
</div>
