package jp.hiroaki.bdbridge

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit
import jp.hiroaki.bdbridge.bridge.NightRun
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * The overnight run, with no screen: the model's (`NightRun`, core/Sources/AndroidBridge/Night.swift), which wakes the
 * recorder, sends what waits for it and for the television, and fetches the guide, as the iOS app's background task
 * does. WorkManager runs it on Wi-Fi, as an unmetered network; whether that Wi-Fi is the one the recorder or the
 * television is on is the run's own first question.
 */
class NightWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        // WorkManager runs a run it stopped again later. The iOS app runs no night twice, and the next night was asked
        // for as the stopped one began.
        if (runAttemptCount > 0) return Result.success()
        Night.ask(applicationContext)
        val run = RecBridge.night(applicationContext)
        val ended = CompletableDeferred<Unit>()
        // Through the bridge's call, which runs Swift's main queue for as long as Swift is at it, and in the bridge's
        // own scope: stopped, this worker ends at once, as the iOS app completes its task without waiting, and the
        // run, told to stop, ends at its next step with its main queue still run.
        RecBridge.launch {
            try {
                RecBridge.call { run.run() }
            } finally {
                ended.complete(Unit)
            }
        }
        try {
            ended.await()
        } finally {
            if (!ended.isCompleted) run.stop()
        }
        return Result.success()
    }
}

/** When the overnight run is asked for, and how. */
object Night {
    /** What each request is tagged with, for the next ask to find the one it replaces. */
    const val TAG = "overnight"

    private val asking = Mutex()

    /**
     * Asks for the next run, at the next 02:00 by the model's rule, on Wi-Fi and charging or not, as the iOS app asks
     * at each start and again as a run begins. One asked for before and not yet begun is replaced, so that one waits at
     * a time, as iOS keeps one; a run under way is left alone, as replacing it would stop it, and it has asked for the
     * next itself. One ask at a time in the process: the app's start and a run's beginning, asking at once, could each
     * find the old request and each leave a new one. A request refused is let go, as the iOS app lets its go.
     */
    suspend fun ask(context: Context) = asking.withLock {
        // On the main thread, as the first call to Swift in a process has to be (RecBridge.night).
        val next = withContext(Dispatchers.Main) { NightRun.nextRun() }
        withContext(Dispatchers.IO) {
            try {
                val work = WorkManager.getInstance(context)
                for (info in work.getWorkInfosByTag(TAG).get()) {
                    if (info.state == WorkInfo.State.ENQUEUED) work.cancelWorkById(info.id).result.get()
                }
                val delay = next * 1000 - System.currentTimeMillis()
                val request = OneTimeWorkRequestBuilder<NightWorker>()
                    .setInitialDelay(delay.coerceAtLeast(0), TimeUnit.MILLISECONDS)
                    .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.UNMETERED).build())
                    .addTag(TAG)
                    .build()
                work.enqueue(request).result.get()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
            }
        }
    }
}
