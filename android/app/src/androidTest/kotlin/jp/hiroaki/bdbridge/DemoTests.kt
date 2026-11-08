package jp.hiroaki.bdbridge

import android.content.Context
import android.view.KeyEvent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The demo, driven through the screens as a person would: the invented recorder (RecorderKit's `DemoRecorder`) and
 * its invented guide, so nothing here reaches the LAN. Before the model first opens in the test's process, what the
 * app keeps is deleted -- a saved address among it -- so that the app opens on the place to choose a recorder whatever
 * the device was last used with; each test leaves the demo again as it ends.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class DemoTests {
    @get:Rule val compose = createEmptyComposeRule()
    private lateinit var scenario: ActivityScenario<MainActivity>

    @Before fun openTheApp() {
        if (!RecBridge.isOpen) {
            val files = ApplicationProvider.getApplicationContext<Context>().filesDir
            File(files, "settings").deleteRecursively()
            files.listFiles { file -> file.name.startsWith("guide") }?.forEach { it.delete() }
        }
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    @After fun closeTheApp() {
        // The demo is left as the reader leaves it, waiting for the model to be free to change the recorder.
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

    /** A recording's row, whose details start with its day and time: `11/8(日) 21:00`. */
    private val startsWithADayAndATime = SemanticsMatcher("starts with a day and a time") { node ->
        node.config.getOrNull(SemanticsProperties.Text).orEmpty().any { Regex("^\\d+/\\d+\\(.\\) \\d\\d:\\d\\d").containsMatchIn(it.text) }
    }

    /** A heading of the reservations, a day: `11/8(日)`. */
    private val aDay = SemanticsMatcher("a day") { node ->
        node.config.getOrNull(SemanticsProperties.Text).orEmpty().any { Regex("^\\d+/\\d+\\(.\\)$").matches(it.text) }
    }

    private fun openTheDemo() {
        compose.waitUntilAtLeastOneExists(hasText("サンプルデータで試す"), 20_000)
        compose.onNodeWithText("サンプルデータで試す").performClick()
        compose.waitUntilAtLeastOneExists(hasText("デモ"), 30_000)
    }

    @Test fun theDemosGuideOpensAtWhatIsOnAndAProgrammeSaysWhatItIs() {
        openTheDemo()
        compose.onNodeWithText("前の日").assertExists()
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
        compose.onAllNodesWithText("放送中")[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("開始"), 10_000)
        compose.onNodeWithText("放送").assertExists()
        compose.onNodeWithText("長さ").assertExists()
        // The back key, as a person closes the sheet; it goes to the sheet's own window.
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilDoesNotExist(hasText("開始"), 10_000)
    }

    @Test fun anotherDayOpensAtItsFirstProgrammeAndTodayAtWhatIsOn() {
        openTheDemo()
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
        compose.onNodeWithText("次の日").performClick()
        // Nothing is on air on another day: today's list, opened at 04:00 between four and five, would pass the
        // second check alone.
        compose.waitUntilDoesNotExist(hasText("放送中"), 10_000)
        compose.waitUntilAtLeastOneExists(hasText("04:00"), 10_000)
        compose.onNodeWithText("前の日").performClick()
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
    }

    @Test fun theDemosReservationsAndRecordingsAreListed() {
        openTheDemo()
        compose.onNodeWithText("予約").performClick()
        compose.waitUntilAtLeastOneExists(aDay, 10_000)
        compose.onNodeWithText("録画").performClick()
        compose.waitUntilAtLeastOneExists(startsWithADayAndATime, 10_000)
    }

    @Test fun leavingTheDemoSaysNoRecorderIsAddedAndOffersTheSearch() {
        openTheDemo()
        // Held while the model is at work on the demo's recorder, as on iOS.
        compose.waitUntilAtLeastOneExists(hasContentDescription("デモを終了") and isEnabled(), 20_000)
        compose.onNodeWithContentDescription("デモを終了").performClick()
        compose.waitUntilAtLeastOneExists(hasText("レコーダーが追加されていません"), 20_000)
        compose.onNodeWithText("レコーダーを探す").performClick()
        compose.waitUntilAtLeastOneExists(hasText("サンプルデータで試す"), 10_000)
    }
}
