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
