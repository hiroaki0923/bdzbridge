<script>
  import { loadPref, savePref } from '../prefs.js'
  import { api, tvDays } from '../api.js'
  import { app } from '../store.svelte.js'
  import ProgramList from './ProgramList.svelte'
  import GuideGrid from './GuideGrid.svelte'
  import ChannelPrefs from './ChannelPrefs.svelte'
  let prefsOpen = $state(false)

  const BTS = [['td', '地デジ'], ['bs', 'BS'], ['cs', 'CS'], ['bs4k', 'BS4K']]
  const days = tvDays()
  let bt = $state(loadPref('bt', null) || 'td')
  let view = $state(loadPref('guideView', null) || 'list')
  let day = $state(days[0].iso)
  let channels = $state([])
  let serviceId = $state(Number(loadPref('ch', null)) || null)
  let programs = $state([])
  let busy = $state(false)
  let error = $state('')

  async function loadChannels() {
    channels = await api('/channels', { query: { broadcasting: bt } })
    if (!channels.some((c) => c.service_id === serviceId)) serviceId = channels[0]?.service_id ?? null
  }
  async function loadPrograms() {
    if (view !== 'grid' && serviceId == null) { programs = []; return }
    busy = true; error = ''
    try {
      programs = view === 'grid'
        ? await api('/programs', { query: { broadcasting: bt, date: day, compact: true, limit: 5000 } })
        : await api('/programs', { query: { broadcasting: bt, service_id: serviceId, date: day } })
    } catch (e) { error = e.message } finally { busy = false }
  }
  $effect(() => { savePref('bt', bt); loadChannels().then(loadPrograms) })
  $effect(() => { if (serviceId != null) savePref('ch', String(serviceId)) })
  $effect(() => { day; serviceId; view; loadPrograms() })
  $effect(() => { savePref('guideView', view) })
</script>

<div class="row" style="justify-content: space-between"><h1>番組表</h1><div class="seg mini"><button class:on={view === 'list'} onclick={() => (view = 'list')}>リスト</button><button class:on={view === 'grid'} onclick={() => (view = 'grid')}>表</button></div></div>
{#if app.status && app.status.epg_capable === false}
  <div class="card"><div class="title">この機種は番組表を提供していません</div><div class="muted">レコーダーの機器記述で EPG_CAP が 00 でした。予約は「予約」タブから時刻指定で作れます。</div></div>
{/if}
<div class="seg">{#each BTS as [id, label]}<button class:on={bt === id} onclick={() => (bt = id)}>{label}</button>{/each}</div>
<div class="chips">{#each days as d}<button class="chip" class:on={day === d.iso} onclick={() => (day = d.iso)}>{d.today ? '今日 ' : ''}{d.label}</button>{/each}<button class="chip" onclick={() => (prefsOpen = true)} title="局の表示と並び順">局の表示…</button></div>
{#if view !== 'grid'}<div class="chips">{#each channels as c}<button class="chip" class:on={serviceId === c.service_id} onclick={() => (serviceId = c.service_id)}>{#if c.logo}<img class="logo" src={c.logo} alt="" />{/if}{c.name}</button>{/each}</div>{/if}
{#if error}<p class="error">{error}</p>{/if}
{#if busy && programs.length === 0}<p class="empty"><span class="spinner"></span>読み込み中</p>
{:else if view === 'grid'}<GuideGrid {channels} {programs} {day} />
{:else}<ProgramList {programs} />{/if}
{#if prefsOpen}<ChannelPrefs {bt} label={BTS.find(([id]) => id === bt)?.[1] ?? bt} onclose={() => (prefsOpen = false)} onchange={() => loadChannels().then(loadPrograms)} />{/if}
