import { api } from './api.js'

// Start a bulk job on the server and follow it until it finishes.
// onProgress receives every polled state ({ id, kind, done, total, cancelled, finished, result }).
export async function runJob(path, body, onProgress, intervalMs = 800) {
  let job = await api(path, { method: 'POST', body })
  onProgress?.(job)
  while (!job.finished) {
    await new Promise((r) => setTimeout(r, intervalMs))
    job = await api(`/jobs/${job.id}`)
    onProgress?.(job)
  }
  if (job.error) throw new Error(job.error)
  return job
}

// Ask the server to stop after the item it is working on; what is done stays done.
export const cancelJob = (id) => api(`/jobs/${id}/cancel`, { method: 'POST' })

// Wording for a finished bulk job: "n 件を削除しました" or, after 中止, how far it got.
export const outcome = (verb, n, job) => (job.cancelled ? `${n} 件を${verb}したところで中止しました` : `${n} 件を${verb}しました`)

// Run a bulk job, mirroring its progress into `setProgress({ id, done, total, cancelled })`; resolves to { ...result, cancelled }.
export async function runBulk(path, body, setProgress, intervalMs = 800) {
  const job = await runJob(path, body, (j) => setProgress({ id: j.id, done: j.done, total: j.total, cancelled: j.cancelled }), intervalMs)
  return { ...job.result, cancelled: job.cancelled }
}
