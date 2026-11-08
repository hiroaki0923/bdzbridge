package jp.hiroaki.bdbridge

import android.content.Context
import android.view.KeyEvent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.isSelectable
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
        compose.waitUntilAtLeastOneExists(hasText("サンプルデータを表示しています"), 30_000)
    }

    /** A destination of the navigation, which is the only selectable node with its label: a row's mark is not. */
    private fun destination(label: String) = compose.onNode(hasText(label) and isSelectable())

    @Test fun theDemosGuideOpensAtWhatIsOnAndAProgrammeSaysWhatItIs() {
        openTheDemo()
        compose.onNodeWithContentDescription("前の日").assertExists()
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
        compose.onNodeWithContentDescription("次の日").performClick()
        // Nothing is on air on another day: today's list, opened at 04:00 between four and five, would pass the
        // second check alone.
        compose.waitUntilDoesNotExist(hasText("放送中"), 10_000)
        compose.waitUntilAtLeastOneExists(hasText("04:00"), 10_000)
        compose.onNodeWithContentDescription("前の日").performClick()
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
    }

    @Test fun theDemosReservationsAndRecordingsAreListed() {
        openTheDemo()
        // The demo's recorder answers at a recorder's pace, a request at a time, and the lists wait their turn behind
        // the connect's own reads: on an emulator just installed, that has gone past ten seconds.
        destination("予約").performClick()
        compose.waitUntilAtLeastOneExists(aDay, 30_000)
        destination("録画").performClick()
        compose.waitUntilAtLeastOneExists(startsWithADayAndATime, 30_000)
    }

    /** A reservation's first line: `21:00 · 54分`. */
    private val aTimeAndALength = SemanticsMatcher("a time and a length") { node ->
        node.config.getOrNull(SemanticsProperties.Text).orEmpty().any { Regex("^\\d\\d:\\d\\d · \\d+分$").matches(it.text) }
    }

    /**
     * A programme of the demo's next day is reserved from its sheet -- the question, 予約する, the sheet closing -- and,
     * its sheet opened again, the recorder's reservation of it is there to delete, which closes the sheet in turn.
     * Writes only to the demo's invented recorder.
     */
    @Test fun aProgrammeIsReservedFromItsSheetAndDeletedAgain() {
        openTheDemo()
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
        compose.onNodeWithContentDescription("次の日").performClick()
        compose.waitUntilDoesNotExist(hasText("放送中"), 10_000)
        compose.waitUntilAtLeastOneExists(hasText("04:00"), 10_000)
        compose.onAllNodesWithText("04:00")[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("録画予約する") and isEnabled(), 30_000)
        compose.onNodeWithText("録画予約する").performClick()
        compose.waitUntilAtLeastOneExists(hasText("この番組を録画予約しますか？"), 10_000)
        compose.onNodeWithText("予約する").performClick()
        compose.waitUntilDoesNotExist(hasText("録画予約する"), 30_000)

        compose.onAllNodesWithText("04:00")[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("予約を削除") and isEnabled(), 30_000)
        compose.onNodeWithText("予約を削除").performClick()
        compose.waitUntilAtLeastOneExists(hasText("この予約を削除しますか？"), 10_000)
        compose.onNodeWithText("削除する").performClick()
        compose.waitUntilDoesNotExist(hasText("予約を削除"), 30_000)
    }

    @Test fun aReservationsSheetOpensFromTheList() {
        openTheDemo()
        destination("予約").performClick()
        compose.waitUntilAtLeastOneExists(aTimeAndALength, 30_000)
        compose.onAllNodes(aTimeAndALength)[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("予約を削除"), 30_000)
        compose.onNodeWithText("登録元").assertExists()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilDoesNotExist(hasText("予約を削除"), 10_000)
    }

    @Test fun aRecordingsSheetOpensFromTheListWithItsPlaybackAndItsDelete() {
        openTheDemo()
        destination("録画").performClick()
        compose.waitUntilAtLeastOneExists(startsWithADayAndATime, 30_000)
        compose.onAllNodes(startsWithADayAndATime)[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("この録画を削除"), 30_000)
        compose.onNodeWithText("テレビで再生").assertExists()
        compose.onNodeWithText("視聴状態").assertExists()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilDoesNotExist(hasText("この録画を削除"), 10_000)
    }

    @Test fun leavingTheDemoSaysNoRecorderIsAddedAndOffersTheSearch() {
        openTheDemo()
        // The strip's 終了, held while the model is at work on the demo's recorder, as on iOS.
        compose.waitUntilAtLeastOneExists(hasText("終了") and isEnabled(), 20_000)
        compose.onNodeWithText("終了").performClick()
        compose.waitUntilAtLeastOneExists(hasText("レコーダーが追加されていません"), 20_000)
        compose.onNodeWithText("レコーダーを探す").performClick()
        compose.waitUntilAtLeastOneExists(hasText("サンプルデータで試す"), 10_000)
    }
}
