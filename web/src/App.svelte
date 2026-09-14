<script>
  import { onMount } from 'svelte'
  import { getToken, ApiError } from './api.js'
  import { app, loadStatus, loadDefaults, loadReservations } from './store.svelte.js'
  import Setup from './lib/Setup.svelte'
  import Guide from './lib/Guide.svelte'
  import Search from './lib/Search.svelte'
  import Reservations from './lib/Reservations.svelte'
  import Titles from './lib/Titles.svelte'
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

  // line icons (24×24, stroked) so the bar looks the same on every platform
  const ICONS = {
    guide: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 9.5h18M9.5 9.5V20M15.5 9.5V20"/>',
    search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l5 5"/>',
    reservations: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.5V12l3 2"/>',
    titles: '<rect x="3" y="5.5" width="18" height="13" rx="2.5"/><path d="M10.5 9.5v5l4.5-2.5z" fill="currentColor" stroke="none"/>',
    settings: '<path d="M4 7h16M4 12h16M4 17h16"/><circle cx="9" cy="7" r="2" fill="var(--tabbar)"/><circle cx="15" cy="12" r="2" fill="var(--tabbar)"/><circle cx="8" cy="17" r="2" fill="var(--tabbar)"/>',
  }
  const tabs = [['guide', '番組表'], ['search', '検索'], ['reservations', '予約'], ['titles', '録画'], ['settings', '設定']]
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
    {:else if app.tab === 'titles'}<Titles />
    {:else}<Settings onreselect={() => (phase = 'recorder')} onlogout={() => (phase = 'token')} />{/if}
  </main>
  <nav class="tabbar">
    {#each tabs as [id, label] (id)}
      <button class:on={app.tab === id} aria-current={app.tab === id ? 'page' : undefined} onclick={() => { app.tab = id; window.scrollTo(0, 0) }}>
        <span class="ico"><svg viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{@html ICONS[id]}</svg></span>
        <span class="lbl">{label}</span>
      </button>
    {/each}
  </nav>
  {#if app.sheet}<ProgramSheet program={app.sheet} onclose={() => (app.sheet = null)} />{/if}
{/if}
{#if app.toast}<div class="toast">{app.toast}</div>{/if}

<style>
  .toast { position: fixed; left: 50%; bottom: calc(84px + env(safe-area-inset-bottom)); transform: translateX(-50%); background: var(--text); color: var(--bg); padding: 8px 14px; border-radius: 999px; font-size: 13px; z-index: 30; white-space: nowrap; }
</style>
