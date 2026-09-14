<script>
  // What the recorder is playing on the TV, with pause / resume / stop.
  import { api } from '../../api.js'
  let { playback, titleOf, onchange } = $props()
  let busy = $state(false)
  const name = $derived(titleOf(playback?.title_id)?.title ?? playback?.title_id)
  async function control(operation) {
    busy = true
    try { onchange(await api('/recorder/playback', { method: 'POST', body: { operation } })) } catch { /* the bar just stays */ } finally { busy = false }
  }
</script>

{#if playback?.play === 'Playing'}
  <div class="card row" style="justify-content: space-between">
    <span><span class="mark now">テレビで再生中</span>{name}{playback.position_sec != null ? ' · ' + Math.floor(playback.position_sec / 60) + '分' : ''}</span>
    <span class="row"><button class="chip" disabled={busy} onclick={() => control('pause')}>一時停止</button><button class="chip" disabled={busy} onclick={() => control('stop')}>停止</button></span>
  </div>
{:else if playback?.play === 'Paused'}
  <div class="card row" style="justify-content: space-between">
    <span><span class="mark">一時停止中</span>{name}</span>
    <span class="row"><button class="chip" disabled={busy} onclick={() => control('resume')}>再開</button><button class="chip" disabled={busy} onclick={() => control('stop')}>停止</button></span>
  </div>
{/if}
