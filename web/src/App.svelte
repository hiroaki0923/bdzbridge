<script>
  import { onMount } from 'svelte'
  import { getToken, ApiError } from './api.js'
  import { app, loadStatus, loadDefaults, loadReservations } from './store.svelte.js'
  import Setup from './lib/Setup.svelte'
  import Guide from './lib/Guide.svelte'
  import Search from './lib/Search.svelte'
  import Reservations from './lib/Reservations.svelte'
  import Settings from './lib/Settings.svelte'
  import ProgramSheet from './lib/ProgramSheet.svelte'

  let phase = $state('boot') // boot | token | recorder | ready
  let bootError = $state('')

  async function boot() {
    bootError = ''
    if (!getToken()) { phase = 'token'; return }
    try {
      const st = await loadStatus()
      if (!st.configured) { phase = 'recorder'; return }
      await Promise.all([loadDefaults(), loadReservations()])
      phase = 'ready'
    } catch (e) {
      if (e instanceof ApiError && e.status === 401) { phase = 'token'; return }
      bootError = e.message
      phase = 'token'
    }
  }
  onMount(boot)

  const tabs = [
    ['guide', '番組表', '📺'], ['search', '検索', '🔍'], ['reservations', '予約', '⏺'], ['settings', '設定', '⚙️'],
  ]
</script>

{#if phase === 'boot'}
  <main><p class="empty"><span class="spinner"></span>接続中…</p></main>
{:else if phase === 'token' || phase === 'recorder'}
  <Setup mode={phase} error={bootError} ondone={boot} />
{:else}
  <main>
    {#if app.tab === 'guide'}<Guide />
    {:else if app.tab === 'search'}<Search />
    {:else if app.tab === 'reservations'}<Reservations />
    {:else}<Settings onreselect={() => (phase = 'recorder')} onlogout={() => (phase = 'token')} />{/if}
  </main>
  <nav class="tabbar">
    {#each tabs as [id, label, ico]}
      <button class:on={app.tab === id} onclick={() => { app.tab = id; window.scrollTo(0, 0) }}><span class="ico">{ico}</span>{label}</button>
    {/each}
  </nav>
  {#if app.sheet}<ProgramSheet program={app.sheet} onclose={() => (app.sheet = null)} />{/if}
{/if}
{#if app.toast}<div class="toast">{app.toast}</div>{/if}

<style>
  .toast { position: fixed; left: 50%; bottom: calc(84px + env(safe-area-inset-bottom)); transform: translateX(-50%); background: var(--text); color: var(--bg); padding: 8px 14px; border-radius: 999px; font-size: 13px; z-index: 30; white-space: nowrap; }
</style>
