package jp.hiroaki.bdbridge

import android.content.Context
import android.view.KeyEvent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasContentDescription
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
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The demo, driven through the screens as a person would: the invented recorder (RecorderKit's `DemoRecorder`) and
 * its invented guide, so nothing here reaches the LAN. A saved address is forgotten first, so that the app opens on
 * the screen that offers the demo whatever the device was last used with.
 */
@OptIn(ExperimentalTestApi::class)
@RunWith(AndroidJUnit4::class)
class DemoTests {
    @get:Rule val compose = createEmptyComposeRule()
    private lateinit var scenario: ActivityScenario<MainActivity>

    @Before fun openTheApp() {
        ApplicationProvider.getApplicationContext<Context>().getSharedPreferences("recbridge", Context.MODE_PRIVATE)
            .edit().clear().commit()
        scenario = ActivityScenario.launch(MainActivity::class.java)
    }

    @After fun closeTheApp() = scenario.close()

    /** A reservation's or a recording's row, which starts with its day: `11/8(日) 21:00`. A guide row starts with its time. */
    private val startsWithADay = SemanticsMatcher("starts with a day") { node ->
        node.config.getOrNull(SemanticsProperties.Text).orEmpty().any { Regex("^\\d+/\\d+\\(.\\) ").containsMatchIn(it.text) }
    }

    private fun openTheDemo() {
        compose.waitUntilAtLeastOneExists(hasText("レコーダーがない場合はデモで試す"), 20_000)
        compose.onNodeWithText("レコーダーがない場合はデモで試す").performClick()
        compose.waitUntilAtLeastOneExists(hasText("デモの番組表を入れました"), 30_000)
    }

    @Test fun theDemosGuideOpensAtWhatIsOnAndAProgrammeSaysWhatItIs() {
        openTheDemo()
        compose.onNodeWithText("デモ").assertExists()
        compose.onNodeWithText("前の日").assertExists()
        compose.waitUntilAtLeastOneExists(hasText("放送中", substring = true), 10_000)
        compose.onAllNodesWithText("放送中", substring = true)[0].performClick()
        compose.waitUntilAtLeastOneExists(hasText("開始"), 10_000)
        compose.onNodeWithText("放送").assertExists()
        compose.onNodeWithText("長さ").assertExists()
        // The back key, as a person closes the sheet; it goes to the sheet's own window.
        InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(KeyEvent.KEYCODE_BACK)
        compose.waitUntilDoesNotExist(hasText("開始"), 10_000)
    }

    @Test fun anotherDayOpensAtItsFirstProgramme() {
        openTheDemo()
        compose.waitUntilAtLeastOneExists(hasText("放送中", substring = true), 10_000)
        compose.onNodeWithText("次の日").performClick()
        compose.waitUntilAtLeastOneExists(hasText("04:00〜", substring = true), 10_000)
        compose.onNodeWithText("前の日").performClick()
        compose.waitUntilAtLeastOneExists(hasText("放送中", substring = true), 10_000)
    }

    @Test fun theDemosReservationsAndRecordingsAreRead() {
        openTheDemo()
        compose.onNodeWithText("予約").performClick()
        compose.waitUntilAtLeastOneExists(startsWithADay, 10_000)
        compose.onNodeWithText("録画").performClick()
        compose.waitUntilAtLeastOneExists(startsWithADay, 10_000)
    }

    @Test fun leavingTheDemoGoesBackToTheRecorderScreen() {
        openTheDemo()
        compose.onNodeWithContentDescription("レコーダーを切り替える").performClick()
        compose.waitUntilAtLeastOneExists(hasText("レコーダーがない場合はデモで試す"), 10_000)
        compose.waitUntilDoesNotExist(hasContentDescription("レコーダーを切り替える"), 10_000)
    }
}
