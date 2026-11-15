package jp.hiroaki.bdbridge

import android.content.Context
import android.os.Process
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.TestListenableWorkerBuilder
import java.io.File
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The overnight run (Night.kt): what the app's start asks WorkManager for, and the worker itself run in the demo. The
 * app is opened as the demo's tests open it, and nothing here reaches the LAN: the demo's recorder is the model's own,
 * and a run in the demo asks nothing.
 */
@RunWith(AndroidJUnit4::class)
class NightTests {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var scenario: ActivityScenario<MainActivity>

    @Before fun openTheApp() {
        if (!RecBridge.isOpen) {
            val files = context.filesDir
            File(files, "settings").deleteRecursively()
            files.listFiles { file -> file.name.startsWith("guide") }?.forEach { it.delete() }
        }
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    @After fun closeTheApp() {
        runBlocking {
            withTimeout(30_000) {
                while (RecBridge.devices.value?.demo != false) {
                    RecBridge.act { it.devices.leaveDemo() }
                    delay(200)
                }
            }
        }
        scenario.close()
    }

    /** The runs asked for that have not begun. */
    private fun waiting(): List<WorkInfo> = WorkManager.getInstance(context).getWorkInfosByTag(Night.TAG).get()
        .filter { it.state == WorkInfo.State.ENQUEUED }

    /**
     * Once the app has started, one run waits: on Wi-Fi (an unmetered network), charging or not, from the next 02:00 in
     * Japan's time, which the model's rule (`BackgroundWork.nextNightlyRun`) names.
     */
    @Test fun theAppsStartAsksForTheNextNight() {
        val asked = runBlocking {
            withTimeout(10_000) {
                while (waiting().isEmpty()) delay(100)
                waiting()
            }
        }
        assertEquals("not one run waits: $asked", 1, asked.size)
        val night = asked.single()
        assertEquals(NetworkType.UNMETERED, night.constraints.requiredNetworkType)
        assertFalse(night.constraints.requiresCharging())
        val tokyo = ZoneId.of("Asia/Tokyo")
        val now = ZonedDateTime.now(tokyo)
        val today = now.withHour(2).withMinute(0).withSecond(0).withNano(0)
        val next = if (today.isAfter(now)) today else today.plusDays(1)
        assertEquals(next.toInstant().toEpochMilli().toDouble(), night.nextScheduleTimeMillis.toDouble(), 1_000.0)
        // Asked for after this process started.
        val started = System.currentTimeMillis() - (SystemClock.elapsedRealtime() - Process.getStartElapsedRealtime())
        assertTrue(night.initialDelayMillis in 1..(night.nextScheduleTimeMillis - started))
    }

    /**
     * The worker itself, run in the demo beside the screens, succeeds having written nothing of the app's: the
     * settings' file is as it was and no guide's cache was made. It asks for the next night as it begins, and one run
     * still waits.
     */
    @Test fun theWorkerInTheDemoSucceedsHavingWrittenNothing() {
        runBlocking {
            withTimeout(30_000) {
                while (RecBridge.devices.value?.demo != true) {
                    RecBridge.act { it.devices.enterDemo() }
                    delay(200)
                }
                while (RecBridge.guide.value?.shows != "programmes") delay(100)
            }
        }
        val files = context.filesDir
        val settings = File(files, "settings/recbridge.plist")
        assertTrue("the settings were never written", settings.exists())
        val before = settings.readBytes()
        val cachesBefore = files.list()!!.filter { it.startsWith("guide") }.sorted()

        val result = runBlocking { TestListenableWorkerBuilder<NightWorker>(context).build().doWork() }

        assertEquals(ListenableWorker.Result.success(), result)
        assertTrue("the settings were written", before.contentEquals(settings.readBytes()))
        assertEquals(cachesBefore, files.list()!!.filter { it.startsWith("guide") }.sorted())
        assertEquals(1, waiting().size)
    }
}
