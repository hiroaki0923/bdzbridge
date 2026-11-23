package jp.hiroaki.bdbridge

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.view.KeyEvent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasScrollToNodeAction
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.isOff
import androidx.compose.ui.test.isOn
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.isSelectable
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.swipeLeft
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
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
        // Under the steps now: a lazy list makes a row only as it is scrolled to.
        compose.waitUntilAtLeastOneExists(hasScrollToNodeAction(), 20_000)
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("サンプルデータで試す"))
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

    /** A block of the grid on the air now: its sentence says so, and a tap opens it. */
    private val aBlockOnAir = hasContentDescription("放送中", substring = true) and hasClickAction()

    /** The guide turned to the grid, put back to the list whatever happens: the mode is kept, as the scale is. */
    private fun inTheGrid(check: () -> Unit) {
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
        val scale = RecBridge.guide.value!!.layout.scale
        try {
            compose.onNodeWithContentDescription("表形式で表示").performClick()
            compose.waitUntilAtLeastOneExists(hasContentDescription("リスト表示にする"), 10_000)
            check()
        } finally {
            runBlocking {
                RecBridge.act { it.guide.keepScale(scale) }
                RecBridge.act { it.guide.showAs(false) }
            }
        }
    }

    /**
     * The guide turned to the grid: the stations across its top, a block on the air whose sheet opens on a tap and
     * closes on the back key, and the grid still there once the activity has been made again.
     */
    @Test fun theGuideTurnsToAGridWhoseBlocksOpenTheirSheets() {
        openTheDemo()
        inTheGrid {
            compose.waitUntilAtLeastOneExists(hasText("サンプルテレビ"), 10_000)
            compose.waitUntilAtLeastOneExists(aBlockOnAir, 10_000)
            compose.onAllNodes(aBlockOnAir)[0].performClick()
            compose.waitUntilAtLeastOneExists(hasText("開始"), 10_000)
            compose.onNodeWithText("長さ").assertExists()
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            compose.waitUntilDoesNotExist(hasText("開始"), 10_000)

            scenario.recreate()
            compose.waitUntilAtLeastOneExists(hasContentDescription("リスト表示にする"), 10_000)
            compose.waitUntilAtLeastOneExists(aBlockOnAir, 10_000)
        }
    }

    /**
     * The zoom buttons: a press of 表示を拡大 makes the blocks taller, and each button stops doing anything at its
     * bound, as the model's scale says.
     */
    @Test fun theGridsZoomButtonsChangeItsScaleAndStopAtTheBounds() {
        openTheDemo()
        inTheGrid {
            compose.waitUntilAtLeastOneExists(aBlockOnAir, 10_000)
            val spoken = compose.onAllNodes(aBlockOnAir)[0].fetchSemanticsNode()
                .config[SemanticsProperties.ContentDescription].first()
            val block = compose.onNode(hasContentDescription(spoken))
            val before = block.fetchSemanticsNode().size.height
            val grow = compose.onNode(hasContentDescription("表示を拡大") and hasClickAction())
            val shrink = compose.onNode(hasContentDescription("表示を縮小") and hasClickAction())
            val scale = RecBridge.guide.value!!.layout.scale
            grow.performClick()
            compose.waitUntil(10_000) { RecBridge.guide.value!!.layout.scale > scale }
            compose.waitUntil(10_000) { block.fetchSemanticsNode().size.height > before }

            // Pressed until it does nothing more, each press waited for: at most as many as the scale has steps.
            val presses = { button: SemanticsNodeInteraction, more: (GridDay) -> Boolean ->
                var count = 0
                while (more(RecBridge.guide.value!!.layout) && count < 10) {
                    val was = RecBridge.guide.value!!.layout.scale
                    button.performClick()
                    compose.waitUntil(10_000) { RecBridge.guide.value!!.layout.scale != was }
                    count++
                }
                count
            }
            assertTrue(presses(grow) { it.canGrow } < 10)
            grow.assertIsNotEnabled()
            assertTrue(RecBridge.guide.value!!.layout.let { it.scale == it.largest })
            assertTrue(presses(shrink) { it.canShrink } < 10)
            shrink.assertIsNotEnabled()
            assertTrue(RecBridge.guide.value!!.layout.let { it.scale == it.smallest })
        }
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

    /**
     * The reservations' menu sorts the list by station and back by day; a row swiped to the left is asked about before
     * anything is deleted, and キャンセル leaves it where it was.
     */
    @Test fun theReservationsAreSortedByTheMenuAndASwipeAsksBeforeDeleting() {
        openTheDemo()
        destination("予約").performClick()
        compose.waitUntilAtLeastOneExists(aDay, 30_000)
        compose.onNodeWithContentDescription("並び順を変更").performClick()
        compose.onNodeWithText("局").performClick()
        compose.waitUntilDoesNotExist(aDay, 10_000)
        compose.onNodeWithContentDescription("並び順を変更").performClick()
        compose.onNodeWithText("日時").performClick()
        compose.waitUntilAtLeastOneExists(aDay, 10_000)

        // A swipe does nothing while the recorder works: its line is waited out first.
        compose.waitUntil(30_000) { RecBridge.reservations.value?.line?.isEmpty() == true }
        val rows = RecBridge.reservations.value!!.sections.sumOf { it.rows.size }
        // A flick that barely moves the row asks nothing; the row drawn well aside does.
        compose.onAllNodes(aTimeAndALength)[0].performTouchInput {
            swipe(center, center - Offset(width * 0.15f, 0f), durationMillis = 60)
        }
        compose.waitForIdle()
        compose.onAllNodesWithText("この予約を削除しますか？").assertCountEquals(0)
        compose.onAllNodes(aTimeAndALength)[0].performTouchInput { swipeLeft() }
        compose.waitUntilAtLeastOneExists(hasText("この予約を削除しますか？"), 10_000)
        compose.onNodeWithText("キャンセル").performClick()
        compose.waitUntilDoesNotExist(hasText("この予約を削除しますか？"), 10_000)
        assert(RecBridge.reservations.value!!.sections.sumOf { it.rows.size } == rows) { "キャンセル deleted a reservation" }
    }

    /**
     * The recordings turned to まとめ, a programme's page opened -- 選択, 削除できるものをすべて選択, the delete at the
     * foot saying as many as are ticked, 選択解除, and the back key closing the page -- and then to 重複, whose scan
     * finds the demo's copy. Reads only. The view picked is kept, so it is put back to 一覧 whatever happens.
     */
    @Test fun theRecordingsAreGatheredIntoProgrammesAndScannedForCopies() {
        openTheDemo()
        destination("録画").performClick()
        compose.waitUntilAtLeastOneExists(startsWithADayAndATime, 30_000)
        try {
            compose.onNodeWithContentDescription("表示を変える").performClick()
            compose.onNodeWithText("まとめ").performClick()
            compose.waitUntilAtLeastOneExists(hasText(" 番組", substring = true), 10_000)
            compose.waitUntil(10_000) { RecBridge.recordings.value?.groups?.isNotEmpty() == true }
            val programme = RecBridge.recordings.value!!.groups.maxBy { it.count.removeSuffix(" 件").toInt() }
            compose.onNodeWithText(programme.name).performClick()
            // Live once the page's window has been read: a press before that does nothing.
            compose.waitUntilAtLeastOneExists(hasText("選択") and hasClickAction() and isEnabled(), 10_000)
            compose.onNode(hasText("選択") and hasClickAction()).performClick()
            compose.waitUntilAtLeastOneExists(hasText("完了"), 10_000)
            compose.onNodeWithText("削除できるものをすべて選択").performClick()
            // The delete at the foot says as many as the selection's bar counts, and no more than the programme has.
            // The bar says 0 件 from the start; what is waited for is the count once the ticks are on.
            val count = SemanticsMatcher("how many are ticked") { node ->
                node.config.getOrNull(SemanticsProperties.Text).orEmpty().any { Regex("^[1-9]\\d* 件$").matches(it.text) }
            }
            compose.waitUntilAtLeastOneExists(count, 10_000)
            val ticked = compose.onNode(count).fetchSemanticsNode().config[SemanticsProperties.Text].first().text
                .removeSuffix(" 件").toInt()
            assertTrue(ticked in 1..programme.count.removeSuffix(" 件").toInt())
            compose.waitUntilAtLeastOneExists(hasText("選択した $ticked 件を削除", substring = true), 10_000)
            compose.onNodeWithText("選択解除").performClick()
            compose.waitUntilDoesNotExist(hasText("選択した ", substring = true), 10_000)
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            compose.waitUntilDoesNotExist(hasText("完了"), 10_000)

            compose.onNodeWithContentDescription("表示を変える").performClick()
            compose.onNodeWithText("重複").performClick()
            compose.waitUntilAtLeastOneExists(hasText("検出を開始"), 10_000)
            compose.onNodeWithText("検出を開始").performClick()
            compose.waitUntilAtLeastOneExists(hasText("残す"), 60_000)
            compose.waitUntilAtLeastOneExists(hasText(" 本 · ", substring = true), 10_000)
        } finally {
            runBlocking {
                RecBridge.act { it.job.clear() }
                RecBridge.act { it.recordings.chooseMode("list") }
            }
        }
    }

    /**
     * おまかせ・まる録 from the reservations: the demo's conditions listed, the form opened by +, held until a word is
     * typed, and a condition registered, which closes the form and is listed. Writes only to the demo's recorder.
     */
    @Test fun aKeywordConditionIsAddedFromItsForm() {
        openTheDemo()
        destination("予約").performClick()
        compose.waitUntilAtLeastOneExists(aDay, 30_000)
        compose.waitUntilAtLeastOneExists(hasContentDescription("おまかせ・まる録") and isEnabled(), 30_000)
        compose.onNodeWithContentDescription("おまかせ・まる録").performClick()
        // The demo's conditions, read as the page opens: one of them names 除外.
        compose.waitUntilAtLeastOneExists(hasText("除外: ", substring = true), 30_000)
        compose.waitUntilAtLeastOneExists(hasContentDescription("条件を追加") and isEnabled(), 30_000)
        compose.onNodeWithContentDescription("条件を追加").performClick()
        // The form read: its field drawn, レコーダーに登録 held while no word is typed.
        compose.waitUntilAtLeastOneExists(hasSetTextAction(), 10_000)
        compose.onNode(hasText("レコーダーに登録") and hasClickAction()).assertIsNotEnabled()
        compose.onAllNodes(hasSetTextAction())[0].performTextInput("ためしの言葉")
        compose.waitUntilAtLeastOneExists(hasText("レコーダーに登録") and isEnabled(), 10_000)
        compose.onNodeWithText("レコーダーに登録").performClick()
        compose.waitUntilDoesNotExist(hasText("レコーダーに登録"), 30_000)
        compose.waitUntilAtLeastOneExists(hasText("ためしの言葉", substring = true) and !hasSetTextAction(), 30_000)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilAtLeastOneExists(aDay, 10_000)
    }

    @Test fun aRecordingsSheetOpensFromTheListWithItsPlaybackAndItsDelete() {
        openTheDemo()
        destination("録画").performClick()
        compose.waitUntilAtLeastOneExists(startsWithADayAndATime, 30_000)
        compose.onAllNodes(startsWithADayAndATime)[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("この録画を削除"), 30_000)
        compose.onNodeWithText("テレビで再生").assertExists()
        compose.onNodeWithText("視聴状態").assertExists()
        // The sheet has the strip of its own, without the demo's line the screen's strip under it says.
        assertTrue(compose.onAllNodes(hasText("サンプルデータを表示しています")).fetchSemanticsNodes().size <= 1)
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

    /**
     * The first screen is the tutorial: what the app is, the four steps (this device's own words for the second),
     * and the ways on, before the demo is entered.
     */
    @Test fun theFirstScreenTellsTheStepsBesideTheSearchAndTheDemo() {
        compose.waitUntilAtLeastOneExists(hasText("セットアップ"), 20_000)
        compose.onNodeWithText("レコーダーとテレビの電源を入れる").assertExists()
        compose.onNodeWithText("この端末をレコーダーやテレビと同じ Wi-Fi につなぐ").assertExists()
        compose.onNodeWithText("あとで設定").assertExists()
        val list = compose.onNode(hasScrollToNodeAction())
        list.performScrollToNode(hasText("見つかったレコーダーやテレビをタップする"))
        compose.onNodeWithText("「レコーダーとテレビを探す」をタップする").assertExists()
        list.performScrollToNode(hasText("サンプルデータで試す"))
        compose.onNodeWithText("いつでも設定から終了できます。", substring = true).assertExists()
        openTheDemo()
    }

    /**
     * In the settings, セットアップ手順を見る opens the steps again with 閉じる in place of あとで設定, and the back key
     * returns to the settings, not to the guide.
     */
    @Test fun theSettingsOpenTheStepsAgainAndTheBackKeyComesBackToThem() {
        openTheDemo()
        destination("設定").performClick()
        compose.waitUntilAtLeastOneExists(hasText("機種"), 30_000)
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("セットアップ手順を見る"))
        compose.onNode(hasText("セットアップ手順を見る") and hasClickAction()).performClick()
        compose.waitUntilAtLeastOneExists(hasText("セットアップ"), 10_000)
        compose.onNodeWithText("レコーダーとテレビの電源を入れる").assertExists()
        compose.onAllNodesWithText("あとで設定").assertCountEquals(0)
        compose.onNodeWithContentDescription("閉じる").assertExists()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilDoesNotExist(hasText("レコーダーとテレビの電源を入れる"), 10_000)
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("セットアップ手順を見る"))
        compose.onNodeWithText("セットアップ手順を見る").assertExists()
    }

    /**
     * A programme open as the device is turned: it is still open, in the activity that was there, which the turn has
     * not made again (what is open is kept in the composition, which a new activity would not have). On a wide
     * screen it goes from the pane onto a sheet and back.
     */
    @Test fun aProgrammeOpenWhenTheDeviceIsTurnedIsStillOpen() {
        openTheDemo()
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
        compose.onAllNodesWithText("放送中")[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("開始"), 10_000)
        var before: MainActivity? = null
        scenario.onActivity { before = it }
        turned {
            compose.waitUntilAtLeastOneExists(hasText("開始"), 10_000)
            compose.onNodeWithText("長さ").assertExists()
            var after: MainActivity? = null
            scenario.onActivity { after = it }
            assertTrue("the turn made the activity again", before === after)
        }
        compose.waitUntilAtLeastOneExists(hasText("開始"), 10_000)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilDoesNotExist(hasText("開始"), 10_000)
    }

    /**
     * Turns the device the other way from how it is -- upright onto its side, or from its side, as a run with two panes
     * starts, upright -- does `check`, and puts the device back as it was however `check` ends.
     */
    private fun turned(check: () -> Unit) {
        var start = Configuration.ORIENTATION_UNDEFINED
        scenario.onActivity { start = it.resources.configuration.orientation }
        try {
            if (start == Configuration.ORIENTATION_LANDSCAPE) {
                turnTo(ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, Configuration.ORIENTATION_PORTRAIT)
            } else {
                turnTo(ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, Configuration.ORIENTATION_LANDSCAPE)
            }
            check()
        } finally {
            turnTo(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED, start)
        }
    }

    /** Asks the activity for an orientation and waits until the configuration it is shown with has it. */
    private fun turnTo(request: Int, orientation: Int) {
        scenario.onActivity { it.requestedOrientation = request }
        compose.waitUntil(10_000) {
            var now = -1
            scenario.onActivity { now = it.resources.configuration.orientation }
            now == orientation
        }
    }

    // MARK: a wide screen's two panes, tried only on a window 840 dp wide or more and skipped on any other

    private fun assumeTwoPanes() {
        var width = 0
        scenario.onActivity { width = it.resources.configuration.screenWidthDp }
        assumeTrue("two panes need a window 840 dp wide", width >= 840)
    }

    /** Whether a node is in the pane at the window's right, 400 dp wide, rather than on a sheet over the middle. */
    private fun inThePane(node: SemanticsNodeInteraction): Boolean {
        var density = 1f
        scenario.onActivity { density = it.resources.displayMetrics.density }
        val width = compose.onRoot().fetchSemanticsNode().size.width
        return node.fetchSemanticsNode().boundsInRoot.left >= width - 400 * density - 1
    }

    /** How many windows there are with something of the app's in them: the activity's, and a sheet, a dialog or a menu. */
    private fun windows() = compose.onAllNodes(isRoot()).fetchSemanticsNodes().size

    /**
     * Two reservations of the list in the order it shows them, each with a title that no other row has and that is no
     * part of another's, so that what has a title can be counted: the row, and the pane's title while it is open.
     */
    private fun twoReservations(): Pair<String, String> {
        val titles = RecBridge.reservations.value!!.sections.flatMap { section -> section.rows.map { it.title } }
        val alone = titles.filter { title ->
            titles.count { it == title } == 1 && titles.none { it != title && (it.contains(title) || title.contains(it)) }
        }
        return alone[0] to alone[1]
    }

    private fun count(title: String) = compose.onAllNodesWithText(title).fetchSemanticsNodes().size

    private fun reservationRow(title: String): SemanticsNodeInteraction {
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText(title))
        return compose.onNode(hasText(title) and hasClickAction())
    }

    /** The reservations, read and with the recorder's line gone, opened at the reservation titled `title`. */
    private fun openReservation(title: String) {
        reservationRow(title).performClick()
        compose.waitUntil(10_000) { count(title) == 2 }
        compose.waitUntilAtLeastOneExists(hasText("予約を削除") and isEnabled(), 30_000)
    }

    private fun theReservations() {
        destination("予約").performClick()
        compose.waitUntilAtLeastOneExists(aTimeAndALength, 30_000)
        compose.waitUntil(30_000) { RecBridge.reservations.value?.line?.isEmpty() == true }
    }

    /**
     * A programme tapped opens beside the list, not on a sheet, and the list stays with the row marked as the one
     * open; another day has the programme no more, and the pane says again that nothing is open.
     */
    @Test fun onAWideScreenAProgrammeOpensBesideTheListAndAnotherDayClearsIt() {
        assumeTwoPanes()
        openTheDemo()
        // Today, whatever day the guide was left at.
        compose.onNodeWithContentDescription("今").performClick()
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
        compose.onNodeWithText(NothingOpenedSays.programme).assertExists()
        compose.onAllNodesWithText("放送中")[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("開始"), 10_000)
        assertTrue("the programme is not in the pane", inThePane(compose.onNodeWithText("開始")))
        compose.onAllNodesWithText(NothingOpenedSays.programme).assertCountEquals(0)
        compose.onAllNodesWithText("放送中")[0].assertIsDisplayed()
        compose.onNode(hasText("放送中") and isSelected()).assertExists()

        compose.onNodeWithContentDescription("次の日").performClick()
        compose.waitUntilDoesNotExist(hasText("開始"), 10_000)
        compose.waitUntilAtLeastOneExists(hasText(NothingOpenedSays.programme), 10_000)
        compose.onNodeWithContentDescription("今").performClick()
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
    }

    /**
     * Another reservation tapped takes the place of the first in the pane, with nothing of the first carried over: its
     * delete asks about the second. キャンセル deletes nothing, and the back key clears the pane.
     */
    @Test fun onAWideScreenAnotherReservationTakesThePlaceOfTheFirstWithNothingCarriedOver() {
        assumeTwoPanes()
        openTheDemo()
        theReservations()
        val (first, second) = twoReservations()
        openReservation(first)
        openReservation(second)
        assertTrue("the first is still in the pane", count(first) == 1)
        // At the pane's foot, under the programme's details.
        compose.onNodeWithText("予約を削除").performScrollTo().performClick()
        compose.waitUntilAtLeastOneExists(hasText("この予約を削除しますか？"), 10_000)
        // The question says the second, beside its row and the pane's title; nothing says the first but its row.
        val saying = { title: String -> compose.onAllNodes(hasText(title, substring = true)).fetchSemanticsNodes().size }
        compose.waitUntil(10_000) { saying(second) == 3 }
        assertTrue("the question is not about the second alone", saying(first) == 1)
        compose.onNodeWithText("キャンセル").performClick()
        compose.waitUntilDoesNotExist(hasText("この予約を削除しますか？"), 10_000)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntil(10_000) { count(second) == 1 }
        compose.waitUntilAtLeastOneExists(hasText(NothingOpenedSays.reservation), 10_000)
    }

    /**
     * While what is open in the pane is held, another row, the top app bar, the navigation rail and the back key do
     * nothing; let go, they do again. The hold is set here as the pane sets it from the model's while a request of
     * the sheet's own is out (`PaneHold`): the demo's recorder answers in 120 ms, too soon to tap anything in.
     */
    @Test fun onAWideScreenAHeldPaneRefusesAnotherRowTheBarsAndTheBackKey() {
        assumeTwoPanes()
        openTheDemo()
        theReservations()
        val (first, second) = twoReservations()
        openReservation(first)
        // Where they are, found before the hold, under which they offer nothing to be found by.
        val row = reservationRow(second).fetchSemanticsNode().boundsInRoot.center
        val rail = destination("録画").fetchSemanticsNode().boundsInRoot.center
        val menu = compose.onNodeWithContentDescription("並び順を変更").fetchSemanticsNode().boundsInRoot.center
        try {
            compose.runOnUiThread { PaneHold.held = true }
            compose.waitForIdle()
            for (place in listOf(row, rail, menu)) {
                compose.onRoot().performTouchInput { click(place) }
                compose.waitForIdle()
            }
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            compose.waitForIdle()
            // Only the pane is to be found while it is held: it has the first, and the sort's menu is not open.
            compose.onNodeWithText(first).assertExists()
            compose.onAllNodesWithText(second).assertCountEquals(0)
            compose.onAllNodesWithText("種類").assertCountEquals(0)
            compose.onNodeWithText("予約を削除").assertExists()
        } finally {
            compose.runOnUiThread { PaneHold.held = false }
        }
        compose.waitUntil(10_000) { count(first) == 2 }
        openReservation(second)
        assertTrue("the first is still in the pane", count(first) == 1)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilAtLeastOneExists(hasText(NothingOpenedSays.reservation), 10_000)
    }

    /**
     * A reservation open in the pane, deleted from the list beside it by a swipe, goes from the pane as it goes from
     * the list. Writes only to the demo's invented recorder, which leaving the demo forgets.
     */
    @Test fun onAWideScreenAReservationDeletedFromTheListBesideClearsThePane() {
        assumeTwoPanes()
        openTheDemo()
        theReservations()
        val (first, _) = twoReservations()
        openReservation(first)
        compose.waitUntil(30_000) { RecBridge.reservations.value?.line?.isEmpty() == true }
        reservationRow(first).performTouchInput { swipeLeft() }
        compose.waitUntilAtLeastOneExists(hasText("この予約を削除しますか？"), 10_000)
        compose.onNodeWithText("削除する").performClick()
        compose.waitUntil(30_000) { count(first) == 0 }
        compose.waitUntilAtLeastOneExists(hasText(NothingOpenedSays.reservation), 10_000)
        compose.onAllNodesWithText("予約を削除").assertCountEquals(0)
    }

    // A turn of a wide screen to under 840 dp and back, as the tablet goes from its side to upright: what is open
    // goes from the pane onto a sheet and back, and stays the same open thing.

    /**
     * The guide's list scrolled well away from what is on now, where it opens, and a programme open beside it: turned,
     * the programme is on a sheet and the list where it was, the same row at its top; turned back, the programme is in
     * the pane again, and the list still where it was. The row at the top, since a list keeps its place by its first
     * row: one further down may go below a shorter list.
     */
    @Test fun onAWideScreenATurnPutsWhatIsOpenOnASheetAndBackWithTheListWhereItWasScrolled() {
        assumeTwoPanes()
        openTheDemo()
        // 今 answered before the list is scrolled: its answer scrolls the list back to what is on now.
        val asked = RecBridge.guide.value!!.nowRequests
        compose.onNodeWithContentDescription("今").performClick()
        compose.waitUntil(10_000) { RecBridge.guide.value!!.nowRequests > asked }
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
        val programmes = RecBridge.guide.value!!.programmes
        val now = System.currentTimeMillis() / 1000
        val opening = programmes.indexOfFirst { it.ends > now }.coerceAtLeast(0)
        // Halfway from it to the day's end, or to its start: well away from it, with rows enough below to fill the list.
        val index = if (opening < programmes.size / 2) (opening + programmes.size) / 2 else opening / 2
        val far = programmes[index]
        val row = hasText(far.title) and hasText(far.time) and hasClickAction()
        compose.onNode(hasScrollToNodeAction()).performScrollToIndex(index)
        compose.onNode(row).performClick()
        compose.waitUntilAtLeastOneExists(hasText("開始"), 10_000)
        assertTrue("the programme is not in the pane", inThePane(compose.onNodeWithText("開始")))
        // Nothing on now is in sight: a list made again would open at it.
        compose.onAllNodesWithText("放送中").assertCountEquals(0)
        turned {
            compose.waitUntil(10_000) { windows() == 2 }
            compose.waitUntilAtLeastOneExists(hasText("開始"), 10_000)
            compose.onNode(row).assertIsDisplayed()
            compose.onAllNodesWithText("放送中").assertCountEquals(0)
        }
        compose.waitUntil(10_000) { windows() == 1 }
        assertTrue("the programme is not in the pane again", inThePane(compose.onNodeWithText("開始")))
        compose.onNode(row).assertIsDisplayed()
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilAtLeastOneExists(hasText(NothingOpenedSays.programme), 10_000)
    }

    /**
     * A pick made in the pane -- 毎回録画 turned from しない to 毎日 -- is what the sheet shows once the device is turned,
     * and the pane once it is turned back: the same window, where one opened again would start at しない. Nothing is
     * reserved; the guide is put back to today whatever happens.
     */
    @Test fun onAWideScreenAPickMadeInThePaneIsStillPickedAfterATurn() {
        assumeTwoPanes()
        openTheDemo()
        compose.onNodeWithContentDescription("今").performClick()
        compose.waitUntilAtLeastOneExists(hasText("放送中"), 10_000)
        try {
            compose.onNodeWithContentDescription("次の日").performClick()
            compose.waitUntilDoesNotExist(hasText("放送中"), 10_000)
            compose.waitUntilAtLeastOneExists(hasText("04:00"), 10_000)
            compose.onAllNodesWithText("04:00")[0].performClick()
            compose.waitUntilAtLeastOneExists(hasText("録画予約する") and isEnabled(), 30_000)
            val never = hasText("しない") and hasClickAction()
            val daily = hasText("毎日") and hasClickAction()
            compose.onNode(never).performClick()
            compose.onNode(daily).performClick()
            compose.waitUntilDoesNotExist(never, 10_000)
            compose.waitUntil(10_000) { windows() == 1 }
            assertTrue("the pick is not in the pane", inThePane(compose.onNode(daily)))
            turned {
                compose.waitUntil(10_000) { windows() == 2 }
                compose.waitUntilAtLeastOneExists(hasText("録画予約する"), 10_000)
                compose.onNode(daily).assertExists()
                compose.onAllNodes(never).assertCountEquals(0)
            }
            compose.waitUntil(10_000) { windows() == 1 }
            assertTrue("the pick is not in the pane again", inThePane(compose.onNode(daily)))
            compose.onAllNodes(never).assertCountEquals(0)
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
            compose.waitUntilAtLeastOneExists(hasText(NothingOpenedSays.programme), 10_000)
        } finally {
            runBlocking { RecBridge.act { it.guide.goToNow() } }
        }
    }

    /**
     * The question 予約を削除 puts up in the pane is still up once the device is turned, over the reservation now on a
     * sheet: the window's, which one opened again would not have. キャンセル deletes nothing, and turned back, the
     * reservation is in the pane again.
     */
    @Test fun onAWideScreenAQuestionUpInThePaneIsStillUpAfterATurn() {
        assumeTwoPanes()
        openTheDemo()
        theReservations()
        val (first, _) = twoReservations()
        val rows = RecBridge.reservations.value!!.sections.sumOf { it.rows.size }
        openReservation(first)
        compose.onNodeWithText("予約を削除").performScrollTo().performClick()
        compose.waitUntilAtLeastOneExists(hasText("この予約を削除しますか？"), 10_000)
        turned {
            compose.waitUntil(10_000) { windows() == 3 }
            compose.onNodeWithText("この予約を削除しますか？").assertExists()
            compose.onNodeWithText("キャンセル").performClick()
            compose.waitUntilDoesNotExist(hasText("この予約を削除しますか？"), 10_000)
            compose.waitUntil(10_000) { windows() == 2 }
        }
        compose.waitUntil(10_000) { windows() == 1 }
        compose.waitUntil(10_000) { count(first) == 2 }
        assertTrue("キャンセル deleted a reservation", RecBridge.reservations.value!!.sections.sumOf { it.rows.size } == rows)
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilAtLeastOneExists(hasText(NothingOpenedSays.reservation), 10_000)
    }

    @Test fun leavingTheDemoSaysNoRecorderIsAddedAndOffersTheSearch() {
        openTheDemo()
        // The strip's 終了, held while the model is at work on the demo's recorder, as on iOS.
        compose.waitUntilAtLeastOneExists(hasText("終了") and isEnabled(), 20_000)
        compose.onNodeWithText("終了").performClick()
        compose.waitUntilAtLeastOneExists(hasText("レコーダーが追加されていません"), 20_000)
        compose.onNodeWithText("レコーダーを探す").performClick()
        compose.waitUntilAtLeastOneExists(hasScrollToNodeAction(), 10_000)
        compose.onNode(hasScrollToNodeAction()).performScrollToNode(hasText("サンプルデータで試す"))
        compose.onNodeWithText("サンプルデータで試す").assertExists()
    }
}
