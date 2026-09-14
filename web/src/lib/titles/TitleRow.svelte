<script>
  // One recorded title in a list: date/time, marks, name, and a line of facts.
  import { fmtDate, fmtTime } from '../../api.js'
  let { title: t, onopen } = $props()
  const facts = $derived(
    `${t.service_name ?? t.broadcasting}${t.genres[0] ? ' · ' + t.genres[0].label : ''} · ${Math.round(t.duration_sec / 60)}分 · ${t.quality}` +
    `${t.size_mb ? ' · ' + (t.size_mb / 1024).toFixed(1) + 'GB' : ''}` +
    `${t.watch_state === 'partway' ? ' · 途中 ' + Math.floor(t.resume_sec / 60) + '分' : t.watch_state === 'watched' ? ' · 視聴済み' : ''}`
  )
</script>

<button class="item" onclick={() => onopen(t)}>
  <span class="time">{fmtDate(t.start)}<br /><span class="muted">{fmtTime(t.start)}</span></span>
  <span>
    {#if t.protected}<span class="lock" title="保護中" aria-label="保護中">🔒</span>{/if}{#if t.is_new}<span class="mark now">NEW</span>{/if}<span class="title">{t.title}</span>
    <div class="sub">{facts}</div>
  </span>
</button>
