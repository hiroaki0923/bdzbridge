<script>
  import { api, fmtDateTime, fmtDate, fmtTime, fmtBytes } from '../api.js'
  import { app, loadStatus, toast } from '../store.svelte.js'
  import { runJob, cancelJob } from '../jobs.js'
  const PAGE = 30
  let mode = $state(localStorage.getItem('bdzbridge.titleMode') || 'list') // list | groups
  $effect(() => { localStorage.setItem('bdzbridge.titleMode', mode) })
  let titles = $state([]) // newest first, 30 at a time (no filter)
  let all = $state(null) // every title; fetched once a genre is chosen
  let hasMore = $state(true)
  let shown = $state(PAGE) // rows shown while a genre is chosen
  let busy = $state(true) // true until the first load finishes, so the empty state never flashes
  let loaded = $state(false)
  let error = $state('')
  let genre = $state(localStorage.getItem('bdzbridge.titleGenre') ?? '') // '' = all, else the ARIB level-1 code
  $effect(() => { localStorage.setItem('bdzbridge.titleGenre', genre) })
  const SORTS = [['newest', '新しい順'], ['oldest', '古い順'], ['size', '大きい順']]
  const STATES = [['unwatched', '未視聴'], ['partway', '途中'], ['watched', '視聴済み']]
  let sort = $state(localStorage.getItem('bdzbridge.titleSort') || 'newest')
  let state = $state(localStorage.getItem('bdzbridge.titleState') ?? '') // '' = all
  $effect(() => { localStorage.setItem('bdzbridge.titleSort', sort); localStorage.setItem('bdzbridge.titleState', state) })
  // anything but the plain newest-first list needs every title in memory
  const needAll = $derived(genre !== '' || state !== '' || sort !== 'newest')
  let selected = $state(null)
  let detail = $state(null)
  let playback = $state(null)
  let playBusy = $state(false)

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
  function refresh() {
    loadStatus().catch(() => {})
    all = null; shown = PAGE
    if (mode === 'dups') { dupPicked = {}; dupJob = null } // the effect below rescans (summaries are cached, so it is quick)
    else if (mode === 'groups') loadGroups(true)
    else { loadPage(true); if (needAll) loadAll() }
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
  function loadMore() { if (needAll) shown += PAGE; else loadPage(false) }
  // a view that needs the full list is still loading until it has arrived, even before the effect that fetches it has run
  const loading = $derived(busy || (needAll && all === null))
  const groupSorters = { newest: (a, b) => new Date(b.latest) - new Date(a.latest), oldest: (a, b) => new Date(a.latest) - new Date(b.latest), size: (a, b) => b.size_mb - a.size_mb }
  const sortedGroups = $derived([...(groups ?? [])].sort(groupSorters[sort]))

  // --- programme groups (まとめ) and bulk delete
  let groups = $state(null)
  let groupsBusy = $state(false)
  let group = $state(null) // the open group
  let members = $state([])
  let picked = $state({}) // id → true
  let confirmBulk = $state(false)
  let bulkBusy = $state(false)
  let progress = $state(null) // { id, done, total, cancelled } while a bulk job runs
  const track = (j) => (progress = { id: j.id, done: j.done, total: j.total, cancelled: j.cancelled })
  async function cancelCurrent() { if (progress?.id) { try { await cancelJob(progress.id); progress = { ...progress, cancelled: true } } catch (e) { error = e.message } } }
  const outcome = (verb, n, job) => (job.cancelled ? `${n} 件を${verb}したところで中止しました` : `${n} 件を${verb}しました`)
  async function loadGroups(refreshList = false) {
    groupsBusy = true; error = ''
    try { groups = await api('/titles/groups', { query: { genre: genre || undefined, refresh: refreshList || undefined } }) }
    catch (e) { error = e.message } finally { groupsBusy = false }
  }
  $effect(() => { genre; if (mode === 'groups') loadGroups() })
  async function openGroup(g) {
    group = g; members = []; picked = {}
    try { members = await api('/titles', { query: { series: g.key, limit: 500 } }) } catch (e) { error = e.message }
  }
  const pickedIds = $derived(Object.keys(picked).filter((id) => picked[id]))
  const pickedSize = $derived(members.filter((m) => picked[m.id]).reduce((s, m) => s + (m.size_mb ?? 0), 0))
  function pickAll(on) { const p = {}; for (const m of members) if (!m.protected) p[m.id] = on; picked = p }
  // the recorder needs a few seconds per title, so the server runs the job in the background and we follow it
  async function deleteIds(ids) {
    const job = await runJob('/titles/delete', { ids }, track)
    return { ...job.result, cancelled: job.cancelled }
  }
  async function bulkDelete() {
    bulkBusy = true; error = ''
    try {
      const res = await deleteIds(pickedIds)
      // titles the recorder no longer lists (deleted elsewhere, or by an earlier job) are gone too
      const gone = new Set([...res.deleted, ...res.skipped.filter((x) => x.reason === 'not found').map((x) => x.id)])
      const other = res.skipped.filter((x) => x.reason !== 'not found')
      const missing = gone.size - res.deleted.length
      toast(`${outcome('削除', res.deleted.length, res)}${missing ? '（' + missing + ' 件は既に消えていました）' : ''}${other.length ? '（' + other.length + ' 件はスキップ）' : ''}`)
      confirmBulk = false; picked = {}
      members = members.filter((m) => !gone.has(m.id))
      titles = titles.filter((t) => !gone.has(t.id))
      if (all) all = all.filter((t) => !gone.has(t.id))
      if (members.length === 0) group = null
      await Promise.all([loadGroups(), loadStatus().catch(() => {})]) // the free-space figure comes from the status
    } catch (e) { error = e.message; confirmBulk = false } finally { bulkBusy = false; progress = null }
  }
  // protect / unprotect many titles through a server-side job (one X_UpdateTitle each), polling for progress
  async function protectIds(ids, on) {
    const job = await runJob('/titles/protect', { ids, protected: on }, track, 600)
    return { ...job.result, cancelled: job.cancelled }
  }
  async function bulkProtect(on, ids = pickedIds) {
    bulkBusy = true; error = ''
    try {
      const res = await protectIds(ids, on)
      const changed = new Set(res.changed)
      for (const list of [members, titles, all ?? []]) for (const m of list) if (changed.has(m.id)) m.protected = on
      toast(outcome(on ? '保護' : '保護解除', res.changed.length, res))
      picked = {}
      await loadGroups(true)
    } catch (e) { error = e.message } finally { bulkBusy = false; progress = null }
  }

  // --- duplicate recordings (same broadcast recorded twice)
  let dupJob = $state(null)
  let dupPicked = $state({})
  let confirmDups = $state(false)
  async function scanDuplicates() {
    error = ''
    try {
      const job = await runJob('/titles/duplicates', undefined, (j) => (dupJob = j), 1000)
      const p = {}
      for (const s of job.result.sets ?? []) for (const id of s.suggest_delete) p[id] = true
      dupPicked = p
    } catch (e) { error = e.message; dupJob = { finished: true, cancelled: false, result: { sets: [] }, total: 0, done: 0 } }
  }
  $effect(() => { if (mode === 'dups' && dupJob === null) scanDuplicates() })
  const dupIds = $derived(Object.keys(dupPicked).filter((id) => dupPicked[id]))
  const dupSize = $derived((dupJob?.result?.sets ?? []).flatMap((s) => s.items).filter((t) => dupPicked[t.id]).reduce((a, t) => a + (t.size_mb ?? 0), 0))
  async function deleteDuplicates() {
    bulkBusy = true; error = ''
    try {
      const res = await deleteIds(dupIds)
      toast(`${outcome('削除', res.deleted.length, res)}${res.skipped.length ? '（' + res.skipped.length + ' 件はスキップ）' : ''}`)
      confirmDups = false; dupPicked = {}; dupJob = null
      titles = titles.filter((t) => !res.deleted.includes(t.id))
      if (all) all = all.filter((t) => !res.deleted.includes(t.id))
      await loadStatus().catch(() => {})
      scanDuplicates()
    } catch (e) { error = e.message; confirmDups = false } finally { bulkBusy = false; progress = null }
  }

  // --- one title: detail sheet, play, protect, delete
  let confirmDelete = $state(false)
  let deleteBusy = $state(false)
  let flagBusy = $state(false)
  async function open(t) {
    selected = t; detail = null
    try { detail = await api(`/titles/${t.id}`) } catch (e) { detail = { summary: '', details: [] } }
  }
  async function deleteTitle() {
    deleteBusy = true; error = ''
    try {
      await api(`/titles/${selected.id}`, { method: 'DELETE' })
      titles = titles.filter((x) => x.id !== selected.id)
      if (all) all = all.filter((x) => x.id !== selected.id)
      members = members.filter((x) => x.id !== selected.id)
      toast('削除しました'); confirmDelete = false; selected = null
      if (mode === 'groups') loadGroups()
      loadStatus().catch(() => {})
    } catch (e) { error = e.message; confirmDelete = false } finally { deleteBusy = false }
  }
  async function setProtected(on) {
    flagBusy = true; error = ''
    try {
      await api(`/titles/${selected.id}`, { method: 'PATCH', body: { protected: on } })
      for (const list of [titles, all ?? [], members]) { const t = list.find((x) => x.id === selected.id); if (t) t.protected = on }
      selected = { ...selected, protected: on }
      toast(on ? '保護しました' : '保護を解除しました')
      if (mode === 'dups') { dupPicked = {}; dupJob = null } // re-evaluate which copy to keep
    } catch (e) { error = e.message } finally { flagBusy = false }
  }
  async function refreshPlayback() {
    try { playback = await api('/recorder/playback') } catch { playback = null }
  }
  async function playOnTv() {
    playBusy = true; error = ''
    try { playback = await api(`/titles/${selected.id}/play`, { method: 'POST' }); toast('テレビで再生を始めました'); selected = null }
    catch (e) { error = e.message; toast('再生できませんでした') } finally { playBusy = false }
  }
  async function control(operation) {
    playBusy = true
    try { playback = await api('/recorder/playback', { method: 'POST', body: { operation } }) } catch (e) { error = e.message } finally { playBusy = false }
  }
  const playingTitle = $derived(playback?.play === 'Playing' ? [...(all ?? titles), ...members].find((t) => t.id === playback.title_id) : null)
</script>

<div class="row" style="justify-content: space-between">
  <h1>録画 {#if app.status?.storage}<span class="muted">残り {fmtBytes(app.status.storage.free_bytes)}</span>{/if}</h1>
  <span class="row">
    <div class="seg mini" style="width: 190px"><button class:on={mode === 'list'} onclick={() => (mode = 'list')}>一覧</button><button class:on={mode === 'groups'} onclick={() => (mode = 'groups')}>まとめ</button><button class:on={mode === 'dups'} onclick={() => (mode = 'dups')}>重複</button></div>
    <button class="chip" disabled={loading || groupsBusy || (mode === 'dups' && dupJob && !dupJob.finished)} onclick={refresh}>{loading || groupsBusy || (mode === 'dups' && dupJob && !dupJob.finished) ? '更新中…' : '更新'}</button>
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
{#if playback?.play === 'Playing'}
  <div class="card row" style="justify-content: space-between">
    <span><span class="mark now">テレビで再生中</span>{playingTitle?.title ?? playback.title_id}{playback.position_sec != null ? ' · ' + Math.floor(playback.position_sec / 60) + '分' : ''}</span>
    <span class="row"><button class="chip" disabled={playBusy} onclick={() => control('pause')}>一時停止</button><button class="chip" disabled={playBusy} onclick={() => control('stop')}>停止</button></span>
  </div>
{:else if playback?.play === 'Paused'}
  <div class="card row" style="justify-content: space-between">
    <span><span class="mark">一時停止中</span>{playingTitle?.title ?? playback.title_id}</span>
    <span class="row"><button class="chip" disabled={playBusy} onclick={() => control('resume')}>再開</button><button class="chip" disabled={playBusy} onclick={() => control('stop')}>停止</button></span>
  </div>
{/if}

{#if mode === 'dups'}
  {#if !dupJob || !dupJob.finished}
    <div class="card">
      <p class="muted" style="margin:0 0 6px"><span class="spinner"></span>重複を調べています{#if dupJob?.total} {dupJob.done} / {dupJob.total}（番組内容を照合中）{/if}</p>
      {#if dupJob?.total}<div class="bar"><div class="fill accent" style="width: {(100 * dupJob.done) / dupJob.total}%"></div></div>{/if}
      <p class="muted">同じタイトルで同じ長さの録画について、レコーダーに番組内容を問い合わせて突き合わせます。初回は時間がかかります。</p>
      {#if dupJob?.id && !dupJob.cancelled}<button class="btn ghost" onclick={() => cancelJob(dupJob.id)}>中止</button>{/if}
    </div>
  {:else}
    <p class="muted">{#if dupJob.cancelled}中止しました。「更新」でやり直せます。{:else}{dupJob.result.sets.length} 組の重複{dupJob.result.sets.length ? '。チェックが付いているのが削除候補で、先に放送された方（保護中や視聴途中のものがあればそちら）を残します。' : 'はありません。'}{/if}</p>
    {#each dupJob.result.sets as s, i (i)}
      <div class="card">
        <div class="title">{s.title}</div>
        <div class="muted">{s.items.length} 本 · 合計 {(s.size_mb / 1024).toFixed(1)}GB · {s.confidence === 'high' ? '番組内容も同じ' : 'タイトルと長さが同じ（内容は未確認）'}</div>
        <div class="list" style="margin-top:8px">
          {#each s.items as t (t.id)}
            <div class="item pick" class:on={dupPicked[t.id]}>
              <label class="check"><input type="checkbox" disabled={t.protected} checked={!!dupPicked[t.id]} onchange={(e) => (dupPicked = { ...dupPicked, [t.id]: e.target.checked })} /></label>
              <button class="pickbody" onclick={() => open(t)}>
                {#if t.protected}<span class="lock">🔒</span>{/if}<span class="mark" class:now={t.id === s.keep} style={t.id === s.keep ? '' : 'background: var(--muted)'}>{t.id === s.keep ? '残す · ' : '候補 · '}{s.reasons[t.id]}</span>
                <div class="sub">{fmtDateTime(t.start)} · {t.service_name ?? t.broadcasting} · {Math.round(t.duration_sec / 60)}分 · {t.quality}{t.size_mb ? ' · ' + (t.size_mb / 1024).toFixed(1) + 'GB' : ''}{t.watch_state === 'partway' ? ' · 途中' : t.watch_state === 'watched' ? ' · 視聴済み' : ' · 未視聴'}</div>
              </button>
            </div>
          {/each}
        </div>
      </div>
    {/each}
    {#if dupIds.length}<button class="btn danger" disabled={bulkBusy} onclick={() => (confirmDups = true)}>選択した {dupIds.length} 件を削除（{(dupSize / 1024).toFixed(1)}GB）</button>{/if}
  {/if}
{:else if mode === 'groups'}
  <div class="list">
    {#if groups === null || (groupsBusy && groups.length === 0)}<p class="empty"><span class="spinner"></span>全件を読み込んでいます</p>
    {:else if groups.length === 0}<p class="empty">録画はありません</p>{/if}
    {#each sortedGroups as g (g.key)}
      <button class="item" onclick={() => openGroup(g)}>
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
    {#each visible as t (t.id)}
      <button class="item" onclick={() => open(t)}>
        <span class="time">{fmtDate(t.start)}<br /><span class="muted">{fmtTime(t.start)}</span></span>
        <span>
          {#if t.protected}<span class="lock" title="保護中" aria-label="保護中">🔒</span>{/if}{#if t.is_new}<span class="mark now">NEW</span>{/if}<span class="title">{t.title}</span>
          <div class="sub">{t.service_name ?? t.broadcasting}{t.genres[0] ? ' · ' + t.genres[0].label : ''} · {Math.round(t.duration_sec / 60)}分 · {t.quality}{t.size_mb ? ' · ' + (t.size_mb / 1024).toFixed(1) + 'GB' : ''}{t.watch_state === 'partway' ? ' · 途中 ' + Math.floor(t.resume_sec / 60) + '分' : t.watch_state === 'watched' ? ' · 視聴済み' : ''}</div>
        </span>
      </button>
    {/each}
  </div>
  {#if more && !loading}<button class="btn ghost" onclick={loadMore}>さらに読み込む</button>{/if}
{/if}

{#if group}
  <div class="sheet-bg" onclick={() => (group = null)} role="presentation"></div>
  <div class="sheet">
    <div class="row" style="justify-content: space-between"><h2>{group.name}</h2><button class="chip" onclick={() => (group = null)}>閉じる</button></div>
    <p class="muted">{members.length} 件 · 合計 {(members.reduce((s, m) => s + (m.size_mb ?? 0), 0) / 1024).toFixed(1)}GB</p>
    <div class="row" style="margin-bottom: 6px; flex-wrap: wrap">
      <button class="chip" onclick={() => pickAll(true)}>保護以外をすべて選択</button><button class="chip" onclick={() => pickAll(false)}>選択解除</button>
      <span class="chip-gap" style="height: 20px"></span>
      <button class="chip" disabled={bulkBusy || !members.length} onclick={() => bulkProtect(true, members.map((m) => m.id))}>🔒 全部を保護</button>
      <button class="chip" disabled={bulkBusy || !members.length} onclick={() => bulkProtect(false, members.map((m) => m.id))}>全部の保護を解除</button>
    </div>
    {#if bulkBusy && progress && !confirmBulk}<p class="muted"><span class="spinner"></span>処理中 {progress.done} / {progress.total} <button class="chip" disabled={progress.cancelled} onclick={cancelCurrent}>{progress.cancelled ? '中止します…' : '中止'}</button></p>{/if}
    <div class="list">
      {#if members.length === 0}<p class="empty"><span class="spinner"></span>読み込み中</p>{/if}
      {#each members as m (m.id)}
        <div class="item pick" class:on={picked[m.id]}>
          <label class="check"><input type="checkbox" disabled={m.protected} checked={!!picked[m.id]} onchange={(e) => (picked = { ...picked, [m.id]: e.target.checked })} /></label>
          <button class="pickbody" onclick={() => open(m)}>
            {#if m.protected}<span class="lock">🔒</span>{/if}{#if m.is_new}<span class="mark now">NEW</span>{/if}<span class="title">{m.title}</span>
            <div class="sub">{fmtDateTime(m.start)} · {m.service_name ?? m.broadcasting} · {Math.round(m.duration_sec / 60)}分{m.size_mb ? ' · ' + (m.size_mb / 1024).toFixed(1) + 'GB' : ''}</div>
          </button>
        </div>
      {/each}
    </div>
    {#if pickedIds.length}
      <button class="btn danger" disabled={bulkBusy} onclick={() => (confirmBulk = true)}>選択した {pickedIds.length} 件を削除（{(pickedSize / 1024).toFixed(1)}GB）</button>
      <button class="btn ghost" disabled={bulkBusy} onclick={() => bulkProtect(true)}>{'選択した ' + pickedIds.length + ' 件を保護'}</button>
      <button class="btn ghost" disabled={bulkBusy} onclick={() => bulkProtect(false)}>{'選択した ' + pickedIds.length + ' 件の保護を解除'}</button>
    {/if}
    {#if error}<p class="error">{error}</p>{/if}
  </div>
{/if}

{#if selected}
  <div class="sheet-bg" onclick={() => (selected = null)} role="presentation" style="z-index: 22"></div>
  <div class="sheet" style="z-index: 23">
    <p class="muted">{fmtDateTime(selected.start)} · {selected.service_name ?? ''}{selected.genres[0] ? ' · ' + selected.genres[0].label : ''} · {Math.round(selected.duration_sec / 60)}分 · {selected.quality}</p>
    <h2>{#if selected.protected}<span class="lock" title="保護中">🔒</span>{/if}{selected.title}</h2>
    {#if detail === null}<p class="muted"><span class="spinner"></span>番組内容を取得中</p>
    {:else}
      {#if detail.summary}<p>{detail.summary}</p>{/if}
      {#each detail.details as d}<p class="muted" style="white-space: pre-wrap">{d}</p>{/each}
    {/if}
    <button class="btn" disabled={playBusy} onclick={playOnTv}>{playBusy ? '電源を入れています…' : 'テレビで再生'}</button>
    <button class="btn ghost" disabled={flagBusy} onclick={() => setProtected(!selected.protected)}>{selected.protected ? '保護を解除する' : '保護する（自動削除させない）'}</button>
    <button class="btn ghost danger-text" disabled={selected.protected} onclick={() => (confirmDelete = true)}>{selected.protected ? '保護中は削除できません' : 'この録画を削除'}</button>
    {#if error}<p class="error">{error}</p>{/if}
    <button class="btn ghost" onclick={() => (selected = null)}>閉じる</button>
  </div>
{/if}

{#if confirmDelete && selected}
  <div class="modal-bg" onclick={() => (confirmDelete = false)} role="presentation"></div>
  <div class="modal" role="dialog" aria-modal="true">
    <div class="title">この録画を削除しますか？</div>
    <p>{selected.title}</p>
    <p class="muted">{fmtDateTime(selected.start)} · {selected.service_name ?? ''} · {Math.round(selected.duration_sec / 60)}分{selected.size_mb ? ' · ' + (selected.size_mb / 1024).toFixed(1) + 'GB' : ''}</p>
    <p class="muted">レコーダーから消えます。元に戻せません。</p>
    <button class="btn danger" disabled={deleteBusy} onclick={deleteTitle}>{deleteBusy ? '削除中…' : '削除する'}</button>
    <button class="btn ghost" disabled={deleteBusy} onclick={() => (confirmDelete = false)}>やめる</button>
  </div>
{/if}

{#if confirmDups}
  <div class="modal-bg" onclick={() => (confirmDups = false)} role="presentation"></div>
  <div class="modal" role="dialog" aria-modal="true">
    <div class="title">重複した {dupIds.length} 件を削除しますか？</div>
    <p class="muted">合計 {(dupSize / 1024).toFixed(1)}GB。それぞれの組で「残す」と付いた方は残ります。レコーダーから消えます。元に戻せません。</p>
    {#if bulkBusy && progress}
      <div class="bar"><div class="fill" style="width: {(100 * progress.done) / Math.max(1, progress.total)}%"></div></div>
      <p class="muted" style="text-align:center">削除中 {progress.done} / {progress.total}</p>
      <button class="btn ghost" disabled={progress.cancelled} onclick={cancelCurrent}>{progress.cancelled ? '中止します…' : '中止（以降は削除しない）'}</button>
    {:else}
      <button class="btn danger" onclick={deleteDuplicates}>{dupIds.length + ' 件を削除する'}</button>
      <button class="btn ghost" onclick={() => (confirmDups = false)}>やめる</button>
    {/if}
  </div>
{/if}

{#if confirmBulk && group}
  <div class="modal-bg" onclick={() => (confirmBulk = false)} role="presentation"></div>
  <div class="modal" role="dialog" aria-modal="true">
    <div class="title">{pickedIds.length} 件を削除しますか？</div>
    <p>{group.name}</p>
    <p class="muted">合計 {(pickedSize / 1024).toFixed(1)}GB。保護中のものは選べません。レコーダーから消えます。元に戻せません。</p>
    {#if bulkBusy && progress}
      <div class="bar"><div class="fill" style="width: {(100 * progress.done) / Math.max(1, progress.total)}%"></div></div>
      <p class="muted" style="text-align:center">削除中 {progress.done} / {progress.total}（1 件に数秒かかります）</p>
      <button class="btn ghost" disabled={progress.cancelled} onclick={cancelCurrent}>{progress.cancelled ? '中止します…' : '中止（以降は削除しない）'}</button>
    {:else}
      <button class="btn danger" onclick={bulkDelete}>{pickedIds.length + ' 件を削除する'}</button>
      <button class="btn ghost" onclick={() => (confirmBulk = false)}>やめる</button>
    {/if}
  </div>
{/if}

<style>
  .chip-gap { flex: 0 0 1px; background: var(--line); margin: 4px 2px; }
  .pick { grid-template-columns: 28px 1fr; align-items: start; }
  .pick.on { background: color-mix(in srgb, var(--accent) 8%, var(--card)); }
  .check { display: flex; align-items: center; height: 100%; padding-top: 2px; }
  .check input { width: 18px; height: 18px; }
  .pickbody { display: block; width: 100%; text-align: left; }
  .bar { height: 8px; border-radius: 4px; background: var(--chip); overflow: hidden; margin-top: 10px; }
  .fill { height: 100%; background: var(--danger); transition: width .3s; }
  .fill.accent { background: var(--accent); }
</style>
