<script>
  import { api } from '../api.js'
  import ProgramList from './ProgramList.svelte'
  let q = $state('')
  let programs = $state([])
  let busy = $state(false)
  let timer
  function schedule() {
    clearTimeout(timer)
    timer = setTimeout(run, 350)
  }
  async function run() {
    const term = q.trim()
    if (term.length < 2) { programs = []; return }
    busy = true
    try { programs = await api('/programs', { query: { q: term, limit: 300 } }) } finally { busy = false }
  }
</script>

<h1>検索</h1>
<input class="search" type="search" placeholder="番組名・説明で検索（8 日分）" bind:value={q} oninput={schedule} />
{#if busy}<p class="muted"><span class="spinner"></span>検索中</p>{/if}
{#if q.trim().length >= 2}<ProgramList {programs} showDate showChannel />{:else}<p class="empty">2 文字以上で検索します</p>{/if}
