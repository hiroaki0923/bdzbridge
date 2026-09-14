<script>
  // Recordings: a paged list with filters, programme groups, and duplicate sets; one detail sheet; the playback bar.
  import { api, fmtBytes, fmtDate } from '../api.js'
  import { app, loadStatus } from '../store.svelte.js'
  import { loadPref, savePref } from '../prefs.js'
  import TitleRow from './titles/TitleRow.svelte'
  import TitleSheet from './titles/TitleSheet.svelte'
  import GroupSheet from './titles/GroupSheet.svelte'
  import DuplicatesView from './titles/DuplicatesView.svelte'
  import PlaybackBar from './titles/PlaybackBar.svelte'

  const PAGE = 30
  const SORTS = [['newest', '新しい順'], ['oldest', '古い順'], ['size', '大きい順']]
  const STATES = [['unwatched', '未視聴'], ['partway', '途中'], ['watched', '視聴済み']]
  let mode = $state(loadPref('titleMode', 'list')) // list | groups | dups
  let genre = $state(loadPref('titleGenre', '')) // '' = all, else the ARIB level-1 code
  let sort = $state(loadPref('titleSort', 'newest'))
  let state = $state(loadPref('titleState', '')) // '' = all, else a watch_state
  $effect(() => { savePref('titleMode', mode); savePref('titleGenre', genre); savePref('titleSort', sort); savePref('titleState', state) })

  // --- the list: newest first in pages, or every title once a filter or another order is chosen
  let titles = $state([])
  let all = $state(null)
  let hasMore = $state(true)
  let shown = $state(PAGE)
  let busy = $state(true) // true until the first load finishes, so the empty state never flashes
  let loaded = $state(false)
  let error = $state('')
  const needAll = $derived(genre !== '' || state !== '' || sort !== 'newest')
  async function loadPage(reset = true) {
    busy = true; error = ''
    try {
      const offset = reset ? 0 : titles.length
      const page = await api('/titles', { query: { limit: PAGE, offset } })
      titles = reset ? page : [...titles, ...page]
      hasMore = page.length === PAGE
      loaded = true
    } catch (e) { error = e.message } finally { busy = false }
  }
  async function loadAll() {
    busy = true; error = ''
    try {
      let list = []
      for (let offset = 0; offset < 3000; offset += 100) {
        const page = await api('/titles', { query: { limit: 100, offset } })
        list = [...list, ...page]
        if (page.length < 100) break
      }
      all = list
      loaded = true
    } catch (e) { error = e.message } finally { busy = false }
  }
  $effect(() => { loadPage(true); refreshPlayback() })
  $effect(() => { genre; state; sort; shown = PAGE; if (needAll && all === null) loadAll() })
  const genres = $derived(Object.entries(app.defaults?.genres ?? {}))
  const counts = $derived.by(() => {
    const m = {}
    for (const t of all ?? []) { const k = String(t.genres[0]?.level1 ?? ''); m[k] = (m[k] ?? 0) + 1 }
    return m
  })
  const byNewest = (a, b) => new Date(b.start) - new Date(a.start)
  const sorters = { newest: byNewest, oldest: (a, b) => -byNewest(a, b), size: (a, b) => (b.size_mb ?? 0) - (a.size_mb ?? 0) || byNewest(a, b) }
  const filtered = $derived.by(() => {
    if (!needAll) return titles
    const list = (all ?? []).filter((t) => (!genre || String(t.genres[0]?.level1 ?? '') === genre) && (!state || t.watch_state === state))
    return [...list].sort(sorters[sort])
  })
  const visible = $derived(needAll ? filtered.slice(0, shown) : titles)
  const more = $derived(needAll ? filtered.length > shown : hasMore && titles.length > 0)
  const loading = $derived(busy || (needAll && all === null))
  function loadMore() { if (needAll) shown += PAGE; else loadPage(false) }

  // --- programme groups
  let groups = $state(null)
  let groupsBusy = $state(false)
  let group = $state(null)
  let groupSheet = $state(null)
  const groupSorters = { newest: (a, b) => new Date(b.latest) - new Date(a.latest), oldest: (a, b) => new Date(a.latest) - new Date(b.latest), size: (a, b) => b.size_mb - a.size_mb }
  const sortedGroups = $derived([...(groups ?? [])].sort(groupSorters[sort]))
  async function loadGroups(refreshList = false) {
    groupsBusy = true; error = ''
    try { groups = await api('/titles/groups', { query: { genre: genre || undefined, refresh: refreshList || undefined } }) }
    catch (e) { error = e.message } finally { groupsBusy = false }
  }
  $effect(() => { genre; if (mode === 'groups') loadGroups() })

  // --- duplicates
  let dupKey = $state(0)
  let dupView = $state(null)

  // --- one open title and the playback bar
  let selected = $state(null)
  let playback = $state(null)
  async function refreshPlayback() {
    try { playback = await api('/recorder/playback') } catch { playback = null }
  }
  const titleOf = (id) => [...(all ?? titles)].find((t) => t.id === id)

  // a child changed titles (deleted some, or flipped protection): keep every list in step
  function applyChange(change) {
    if (change.deleted) {
      const gone = new Set(change.deleted)
      titles = titles.filter((t) => !gone.has(t.id))
      if (all) all = all.filter((t) => !gone.has(t.id))
      if (selected && gone.has(selected.id)) selected = null
      loadStatus().catch(() => {}) // the free-space figure comes from the status
      if (mode === 'groups') loadGroups()
    }
    if (change.protected) {
      for (const list of [titles, all ?? []]) for (const t of list) if (t.id in change.protected) t.protected = change.protected[t.id]
      if (mode === 'groups') loadGroups(true)
    }
    groupSheet?.apply(change)
    dupView?.apply(change)
  }
  function refresh() {
    loadStatus().catch(() => {})
    all = null; shown = PAGE
    if (mode === 'dups') dupKey += 1
    else if (mode === 'groups') loadGroups(true)
    else { loadPage(true); if (needAll) loadAll() }
  }
</script>

<div class="row" style="justify-content: space-between">
  <h1 style="white-space: nowrap">録画 {#if app.status?.storage}<span class="muted" style="font-size: 12px">残り {fmtBytes(app.status.storage.free_bytes)}</span>{/if}</h1>
  <span class="row" style="gap: 6px">
    <div class="seg mini" style="width: 168px"><button class:on={mode === 'list'} onclick={() => (mode = 'list')}>一覧</button><button class:on={mode === 'groups'} onclick={() => (mode = 'groups')}>まとめ</button><button class:on={mode === 'dups'} onclick={() => (mode = 'dups')}>重複</button></div>
    <button class="chip" disabled={loading || groupsBusy} onclick={refresh}>{loading || groupsBusy ? '更新中…' : '更新'}</button>
  </span>
</div>
{#if mode !== 'dups'}
  <div class="chips">
    <button class="chip" class:on={genre === ''} onclick={() => (genre = '')}>すべて</button>
    {#each genres as [k, label] (k)}
      {#if all === null || counts[k]}<button class="chip" class:on={genre === k} onclick={() => (genre = k)}>{label}{counts[k] ? ' ' + counts[k] : ''}</button>{/if}
    {/each}
  </div>
  <div class="chips">
    {#each SORTS as [id, label] (id)}<button class="chip" class:on={sort === id} onclick={() => (sort = id)}>{label}</button>{/each}
    <span class="chip-gap"></span>
    {#each STATES as [id, label] (id)}<button class="chip" class:on={state === id} onclick={() => (state = state === id ? '' : id)}>{label}</button>{/each}
  </div>
{/if}
{#if error}<p class="error">{error}</p>{/if}
<PlaybackBar {playback} {titleOf} onchange={(p) => (playback = p)} />

{#if mode === 'dups'}
  <DuplicatesView bind:this={dupView} refreshKey={dupKey} onopen={(t) => (selected = t)} onchanged={applyChange} />
{:else if mode === 'groups'}
  <div class="list">
    {#if groups === null || (groupsBusy && groups.length === 0)}<p class="empty"><span class="spinner"></span>全件を読み込んでいます</p>
    {:else if groups.length === 0}<p class="empty">録画はありません</p>{/if}
    {#each sortedGroups as g (g.key)}
      <button class="item" onclick={() => (group = g)}>
        <span class="time">{g.count}<span class="muted"> 件</span></span>
        <span>
          {#if g.protected_count}<span class="lock" title="保護あり">🔒</span>{/if}{#if g.new_count}<span class="mark now">NEW {g.new_count}</span>{/if}<span class="title">{g.name}</span>
          <div class="sub">{fmtDate(g.earliest)}{g.count > 1 ? ' 〜 ' + fmtDate(g.latest) : ''} · 合計 {(g.size_mb / 1024).toFixed(1)}GB{g.protected_count ? ' · 保護 ' + g.protected_count + ' 件' : ''}</div>
        </span>
      </button>
    {/each}
  </div>
{:else}
  <div class="list">
    {#if visible.length === 0}<p class="empty">{#if loading}<span class="spinner"></span>{needAll ? '全件を読み込んでいます' : '読み込み中'}{:else if loaded}{needAll ? '条件に合う録画はありません' : '録画はありません'}{/if}</p>{/if}
    {#each visible as t (t.id)}<TitleRow title={t} onopen={(x) => (selected = x)} />{/each}
  </div>
  {#if more && !loading}<button class="btn ghost" onclick={loadMore}>さらに読み込む</button>{/if}
{/if}

{#if group}<GroupSheet bind:this={groupSheet} {group} onopen={(t) => (selected = t)} onclose={() => (group = null)} onchanged={applyChange} />{/if}
{#if selected}<TitleSheet title={selected} onclose={() => (selected = null)} onchanged={applyChange} onplayback={(p) => (playback = p)} />{/if}
