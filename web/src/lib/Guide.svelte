<script>
  import { api, tvDays } from '../api.js'
  import { app } from '../store.svelte.js'
  import ProgramList from './ProgramList.svelte'

  const BTS = [['td', '地デジ'], ['bs', 'BS'], ['cs', 'CS'], ['bs4k', 'BS4K']]
  const days = tvDays()
  let bt = $state(localStorage.getItem('recbridge.bt') || 'td')
  let day = $state(days[0].iso)
  let channels = $state([])
  let serviceId = $state(Number(localStorage.getItem('recbridge.ch')) || null)
  let programs = $state([])
  let busy = $state(false)
  let error = $state('')

  async function loadChannels() {
    channels = await api('/channels', { query: { broadcasting: bt } })
    if (!channels.some((c) => c.service_id === serviceId)) serviceId = channels[0]?.service_id ?? null
  }
  async function loadPrograms() {
    if (serviceId == null) { programs = []; return }
    busy = true; error = ''
    try { programs = await api('/programs', { query: { broadcasting: bt, service_id: serviceId, date: day } }) }
    catch (e) { error = e.message } finally { busy = false }
  }
  $effect(() => { localStorage.setItem('recbridge.bt', bt); loadChannels().then(loadPrograms) })
  $effect(() => { if (serviceId != null) localStorage.setItem('recbridge.ch', String(serviceId)) })
  $effect(() => { day; serviceId; loadPrograms() })
</script>

<h1>番組表</h1>
{#if app.status && app.status.epg_capable === false}
  <div class="card"><div class="title">この機種は番組表を提供していません</div><div class="muted">レコーダーの機器記述で EPG_CAP が 00 でした。予約は「予約」タブから時刻指定で作れます。</div></div>
{/if}
<div class="seg">{#each BTS as [id, label]}<button class:on={bt === id} onclick={() => (bt = id)}>{label}</button>{/each}</div>
<div class="chips">{#each days as d}<button class="chip" class:on={day === d.iso} onclick={() => (day = d.iso)}>{d.today ? '今日 ' : ''}{d.label}</button>{/each}</div>
<div class="chips">{#each channels as c}<button class="chip" class:on={serviceId === c.service_id} onclick={() => (serviceId = c.service_id)}>{c.name}</button>{/each}</div>
{#if error}<p class="error">{error}</p>{/if}
{#if busy && programs.length === 0}<p class="empty"><span class="spinner"></span>読み込み中</p>{:else}<ProgramList {programs} />{/if}
