package jp.hiroaki.bdbridge

import android.content.Context
import android.view.KeyEvent
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.isOff
import androidx.compose.ui.test.isOn
import androidx.compose.ui.test.isSelectable
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
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

    /**
     * A destination of the navigation, which is the only tab with its label: a row's mark is not selectable, and the
     * search's chip of the same name is not a tab.
     */
    private fun destination(label: String) =
        compose.onNode(hasText(label) and isSelectable() and SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Tab))

    /** One of the search's three chips. */
    private fun scope(label: String) =
        compose.onNode(hasText(label) and isSelectable() and !SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Tab))

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

    /** How many the guide's search found, over the results: `番組表 12 件`, `番組表 300 件以上`. */
    private val howManyProgrammes = SemanticsMatcher("how many programmes were found") { node ->
        node.config.getOrNull(SemanticsProperties.Text).orEmpty().any { Regex("^番組表 \\d+ 件").containsMatchIn(it.text) }
    }

    /**
     * The search finds programmes of the guide by a word typed, each with the day it is on, and opens one's sheet;
     * turned to the recordings, it finds one by its title and opens that one's.
     */
    @Test fun theSearchFindsAProgrammeAndARecording() {
        openTheDemo()
        destination("検索").performClick()
        compose.waitUntilAtLeastOneExists(hasText("番組表を検索"), 10_000)
        compose.onNode(hasSetTextAction()).performTextInput("ニュース")
        compose.waitUntilAtLeastOneExists(howManyProgrammes, 30_000)
        val found = hasText("ニュース", substring = true) and hasClickAction() and !hasSetTextAction()
        compose.waitUntilAtLeastOneExists(found and aDay, 10_000)
        compose.onAllNodes(found and aDay)[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("開始"), 10_000)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilDoesNotExist(hasText("開始"), 10_000)

        compose.onNodeWithContentDescription("消去").performClick()
        scope("録画").performClick()
        compose.waitUntilAtLeastOneExists(hasText("録画を検索"), 10_000)
        // The recordings are read as the scope is turned to; one of them is looked for by its own title.
        compose.waitUntil(30_000) { RecBridge.recordings.value?.rows?.isNotEmpty() == true }
        val title = RecBridge.recordings.value!!.rows.first().title
        compose.onNode(hasSetTextAction()).performTextInput(title)
        compose.waitUntilAtLeastOneExists(startsWithADayAndATime, 30_000)
        compose.onAllNodes(startsWithADayAndATime)[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("この録画を削除"), 30_000)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilDoesNotExist(hasText("この録画を削除"), 10_000)
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
        // The sheet itself gone, not only its button: 録画予約する goes as the reservation is made, while the sheet still
        // slides away, and a tap then goes to the sheet going.
        compose.waitUntilDoesNotExist(hasText("長さ"), 30_000)

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

    /**
     * The settings say the demo's recorder, and the stations' page opens from them: a station turned off, and the back
     * key going back to the settings. Writes only to the demo's guide, which leaving the demo deletes.
     */
    @Test fun theSettingsSayTheRecorderAndOpenTheStations() {
        openTheDemo()
        destination("設定").performClick()
        compose.waitUntilAtLeastOneExists(hasText("機種"), 30_000)
        // The settings are a lazy list: a row past the screen's foot is made only as it is scrolled to.
        val settings = compose.onNode(hasScrollToNodeAction())
        settings.performScrollToNode(hasText("状態"))
        settings.performScrollToNode(hasText("チャンネルの表示と並び順"))
        compose.onNodeWithText("チャンネルの表示と並び順").performClick()
        compose.waitUntilAtLeastOneExists(isToggleable() and isOn(), 10_000)
        compose.onAllNodes(isToggleable())[0].performClick()
        compose.waitUntilAtLeastOneExists(isToggleable() and isOff(), 10_000)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilDoesNotExist(isToggleable(), 10_000)
        compose.onNodeWithText("チャンネルの表示と並び順").assertExists()
    }

    /**
     * The demo's television, found by the settings' search, tapped, and registered by the number its sheet says; then
     * listed in the settings' part for it, and taken away again after the question.
     */
    @Test fun theDemosTelevisionIsFoundRegisteredAndTakenAwayInTheSettings() {
        openTheDemo()
        destination("設定").performClick()
        compose.waitUntilAtLeastOneExists(hasText("機種"), 30_000)
        val settings = compose.onNode(hasScrollToNodeAction())
        settings.performScrollToNode(hasText("アドレスを入力して追加"))
        settings.performScrollToNode(hasText("レコーダーとテレビを探す"))
        compose.onNode(hasText("レコーダーとテレビを探す") and hasClickAction()).performClick()
        // Once the search has ended, which it says: before that a recorder found after the television puts its row
        // above the television's, and a tap on the television's row as it moves goes nowhere.
        compose.waitUntilAtLeastOneExists(hasText("テレビが 1 台見つかりました", substring = true), 60_000)
        settings.performScrollToNode(hasText("KJ-SAMPLE"))
        compose.onNode(hasText("KJ-SAMPLE") and hasClickAction()).performClick()
        compose.waitUntilAtLeastOneExists(hasText("4 桁の番号"), 30_000)
        compose.onNode(hasText("4 桁の番号") and hasSetTextAction()).performTextInput("1234")
        // The sheet's button, and not the found television's row beneath it, which says 登録する too.
        val register = hasText("登録する") and hasClickAction() and !hasText("KJ-SAMPLE")
        compose.waitUntilAtLeastOneExists(register and isEnabled(), 10_000)
        compose.onNode(register).performClick()
        compose.waitUntilDoesNotExist(hasText("4 桁の番号"), 30_000)

        settings.performScrollToNode(hasText("テレビを外す"))
        compose.onNode(hasText("テレビを外す") and hasClickAction()).performClick()
        compose.waitUntilAtLeastOneExists(hasText("テレビを外しますか？"), 10_000)
        compose.onNode(hasText("外す") and hasClickAction()).performClick()
        compose.waitUntilDoesNotExist(hasText("テレビを外す"), 10_000)
        settings.performScrollToNode(hasText("アドレスを入力して追加"))
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
