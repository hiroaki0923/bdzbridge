<script>
  // Every bulk job still running on the server, with progress and 中止 — independent of the sheet that started it.
  import { cancelJob, jobs, kindLabel } from '../../jobs.svelte.js'
  let { except = null } = $props() // a job kind some view on screen already shows with its own progress and 中止
  const running = $derived(Object.values(jobs.active).filter((j) => j.kind !== except))
  async function cancel(j) { try { await cancelJob(j.id); jobs.active[j.id] = { ...j, cancelled: true } } catch { /* the next poll shows the state */ } }
</script>

{#each running as j (j.id)}
  <div class="card row" style="justify-content: space-between; gap: 10px">
    <span style="flex: 1; min-width: 0">
      <span class="spinner"></span>{kindLabel(j.kind)}中{#if j.total} {j.done} / {j.total}{/if}{#if j.cancelled} · 中止します…{/if}
      {#if j.total}<div class="bar" style="margin-top: 6px"><div class="fill" class:accent={j.kind !== 'delete'} style="width: {(100 * j.done) / j.total}%"></div></div>{/if}
    </span>
    <button class="chip" disabled={j.cancelled} onclick={() => cancel(j)}>中止</button>
  </div>
{/each}
