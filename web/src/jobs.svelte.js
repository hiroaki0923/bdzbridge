import { api } from './api.js'

// Bulk jobs (delete / protect / duplicate scan) run on the server; this follows them and keeps the running ones in
// `jobs.active` so the recordings screen can show progress and offer 中止 even after the sheet that started one is gone.
export const jobs = $state({ active: {} }) // id → latest snapshot of a job that has not finished

const KIND = { delete: '削除', protect: '保護の変更', duplicates: '重複の検出' }
export const kindLabel = (k) => KIND[k] ?? k

// Wording for a finished bulk job: "n 件を削除しました" or, after 中止, how far it got.
export const outcome = (verb, n, job) => (job.cancelled ? `${n} 件を${verb}したところで中止しました` : `${n} 件を${verb}しました`)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// Poll a job until it finishes; onProgress receives every state ({ id, kind, done, total, cancelled, finished, result }).
export async function followJob(job, onProgress, intervalMs = 800) {
  jobs.active[job.id] = job
  onProgress?.(job)
  try {
    while (!job.finished) {
      await sleep(intervalMs)
      job = await api(`/jobs/${job.id}`)
      jobs.active[job.id] = job
      onProgress?.(job)
    }
  } finally { delete jobs.active[job.id] }
  if (job.error) throw new Error(job.error)
  return job
}

// Start a job on the server and follow it.
export async function runJob(path, body, onProgress, intervalMs = 800) {
  return followJob(await api(path, { method: 'POST', body }), onProgress, intervalMs)
}

// Run a bulk job, mirroring its progress into `setProgress({ id, done, total, cancelled })`; resolves to { ...result, cancelled }.
export async function runBulk(path, body, setProgress, intervalMs = 800) {
  const job = await runJob(path, body, (j) => setProgress({ id: j.id, done: j.done, total: j.total, cancelled: j.cancelled }), intervalMs)
  return { ...job.result, cancelled: job.cancelled }
}

// Ask the server to stop after the item it is working on; what is done stays done.
export const cancelJob = (id) => api(`/jobs/${id}/cancel`, { method: 'POST' })

// After a reload or a tab change: pick up jobs that are still running and call onDone when each finishes.
export async function attachRunningJobs(onDone) {
  let list
  try { list = await api('/jobs') } catch { return }
  for (const j of list) if (!j.finished && !jobs.active[j.id]) followJob(j).then((done) => onDone?.(done)).catch(() => {})
}
