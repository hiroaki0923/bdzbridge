package jp.hiroaki.bdbridge.helper

import android.app.Dialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.util.TypedValue
import android.view.FocusFinder
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.Window
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.abs

/*
 * The parts the helper's screen is made of. The screen is seen from a sofa and worked with the television's
 * remote only, so what matters most is that the button the remote is on can be told at a glance from three
 * metres, and that no text is too small to read from there.
 */

internal val SCREEN_BACKGROUND = Color.rgb(16, 20, 28)
internal val TEXT_BRIGHT = Color.WHITE
internal val TEXT_DIM = Color.rgb(170, 176, 186)
private val OUTLINE = Color.rgb(128, 136, 150)
private val FOCUSED_FILL = Color.rgb(246, 248, 251)
private val PRESSED_FILL = Color.rgb(188, 198, 212)
private val PANEL = Color.rgb(34, 40, 52)
private val PANEL_OUTLINE = Color.rgb(72, 80, 94)

/** How much larger the button the remote is on grows, and how quickly. */
private const val GROWN = 1.08f
private const val GROW_MS = 120L

internal fun Context.dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

internal fun Context.text(s: String, sp: Float, bold: Boolean = false, dim: Boolean = false): TextView = TextView(this).apply {
    text = s
    setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
    setTextColor(if (dim) TEXT_DIM else TEXT_BRIGHT)
    if (bold) setTypeface(typeface, Typeface.BOLD)
    // Lines a little over 1.3 times the text's size apart, rather than the 1.45 the platform takes from the
    // Japanese font: still open enough to read from the sofa, and what lets every line of the state fit at once.
    isFallbackLineSpacing = false
    setLineSpacing(0f, 1.12f)
}

/**
 * A button for the remote. While the remote is elsewhere it is an outline on the dark screen with light text;
 * while the remote is on it, it is filled white with dark text and a little larger, so that the one the centre
 * key will press is the first thing the eye lands on. Pressed, the fill dims for as long as the key is held.
 * It grows from the side it is lined up on (`growFrom` 0 for its left edge, 1 for its right), so that it keeps
 * that edge in line with the text around it and never grows over its neighbour. While a window over the screen
 * has the remote (a question asked over it, say), the button the remote was on looks like the others until that
 * window goes.
 */
internal fun Context.remoteButton(label: String, growFrom: Float = 0f, onClick: () -> Unit): Button = object : Button(this) {
    override fun onWindowFocusChanged(hasWindowFocus: Boolean) {
        super.onWindowFocusChanged(hasWindowFocus)
        if (isFocused) grow(this, hasWindowFocus)
    }
}.apply {
    text = label
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
    isAllCaps = false
    // The theme's button lifts itself with a shadow when pressed; the fill says that here.
    stateListAnimator = null
    val focusedHere = intArrayOf(android.R.attr.state_focused, android.R.attr.state_window_focused)
    background = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_pressed), shape(PRESSED_FILL, PRESSED_FILL))
        addState(focusedHere, shape(FOCUSED_FILL, FOCUSED_FILL))
        addState(intArrayOf(), shape(Color.TRANSPARENT, OUTLINE))
    }
    setTextColor(ColorStateList(
        arrayOf(intArrayOf(android.R.attr.state_pressed), focusedHere, intArrayOf()),
        intArrayOf(SCREEN_BACKGROUND, SCREEN_BACKGROUND, TEXT_BRIGHT)))
    minWidth = 0
    minHeight = dp(44)
    minimumHeight = dp(44)
    setPadding(dp(24), dp(6), dp(24), dp(6))
    isFocusable = true
    setOnClickListener { onClick() }
    addOnLayoutChangeListener { v, left, top, right, bottom, _, oldTop, _, oldBottom ->
        v.pivotX = (right - left) * growFrom
        v.pivotY = (bottom - top) / 2f
        // Moved while the remote is on it, by a line added above it when the screen is drawn again, say: it is
        // brought back into view by where it now is, before the frame is drawn.
        if (v.isFocused && (top != oldTop || bottom != oldBottom)) inView(v)
    }
    setOnFocusChangeListener { v, focused -> grow(v, focused) }
}

/**
 * Grows a button the remote has come to, and gives a button it has left its own size back. One the focus is
 * handed to under a question grows when the question has gone and its window has the remote again.
 */
internal fun grow(view: View, focused: Boolean) {
    val scale = if (focused && view.hasWindowFocus()) GROWN else 1f
    view.animate().scaleX(scale).scaleY(scale).setDuration(GROW_MS).start()
    if (focused) inView(view)
}

/**
 * Asks the pane a button is in to scroll it into view. It brings in the room the button grows into as well as
 * the button itself, so that its edge is never cut.
 */
internal fun inView(view: View) {
    val room = (view.height * (GROWN - 1f)).toInt()
    view.requestRectangleOnScreen(Rect(0, -room, view.width, view.height + room))
}

private fun Context.shape(fill: Int, stroke: Int): Drawable = GradientDrawable().apply {
    cornerRadius = dp(8).toFloat()
    setColor(fill)
    setStroke(dp(2), stroke)
}

/**
 * A question asked over the screen, for the remote: what is asked, under it and dimmer what follows from it, and
 * two buttons side by side, the one that changes nothing on the left. The remote starts on that one, LEFT and
 * RIGHT move between the two, and BACK is the same as pressing it. It is the platform's own dialog, which keeps
 * the remote inside it while it is open; the screen behind is dimmed, and the panel sits in the middle, well
 * inside the edge a television may crop. It is returned to be shown, and gone once either button is pressed.
 */
internal fun Context.question(asked: String, detail: String, no: String, yes: String, onYes: () -> Unit): Dialog {
    val dialog = Dialog(this)
    val stay = remoteButton(no) { dialog.cancel() }.apply { isFocusedByDefault = true }
    val go = remoteButton(yes) {
        dialog.dismiss()
        onYes()
    }
    val panel = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(32), dp(28), dp(32), dp(24))
        background = shape(PANEL, PANEL_OUTLINE)
        // The question wraps rather than being cut, however long the name in it.
        addView(text(asked, 22f))
        addView(text(detail, 18f, dim = true), LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply {
            topMargin = dp(10)
        })
        // Each button with room around it to grow into: a margin, which the row draws in, where padding would cut
        // the grown button off.
        val side = { start: Int ->
            LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply {
                marginStart = dp(start)
                topMargin = dp(4)
                bottomMargin = dp(4)
            }
        }
        addView(LinearLayout(this@question).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(stay, side(0))
            addView(go, side(24))
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(20) })
    }
    dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
    dialog.setContentView(panel)
    dialog.window?.apply {
        // The panel draws its own background; the window's frame, title and buttons are not used.
        setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        setLayout(dp(560), WRAP_CONTENT)
        addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        setDimAmount(0.6f)
    }
    return dialog
}

/**
 * One of the screen's two columns. The remote's up and down keys stay inside it: they go to the next of its own
 * buttons that way, and at its top or its bottom they do nothing, rather than jumping to whatever lies higher or
 * lower in the other column. The next button is looked for among the column's own; with larger text a button of
 * the other column can lie nearer than the next one in this, and a search of the whole screen would find that one
 * and leave the key doing nothing. The key toward the other column (`acrossKey`) goes to the button there at the
 * height nearest the one the remote is on, among those on the screen; the platform would weigh a wide button's
 * nearer edge over its height, and send the remote lower than the eye expects. The key away from the other
 * column does nothing.
 */
internal class Column(context: Context) : LinearLayout(context) {
    var across: Column? = null
    var acrossKey = FOCUS_RIGHT

    init {
        orientation = VERTICAL
    }

    override fun focusSearch(focused: View?, direction: Int): View? = when {
        focused == null -> super.focusSearch(null, direction)
        direction == FOCUS_UP || direction == FOCUS_DOWN -> FocusFinder.getInstance().findNextFocus(this, focused, direction)
        direction == acrossKey -> across?.nearestInHeight(focused)
        direction == FOCUS_LEFT || direction == FOCUS_RIGHT -> null
        else -> super.focusSearch(focused, direction)
    }

    private fun nearestInHeight(from: View): View? {
        val height = middle(from)
        return getFocusables(FOCUS_DOWN).filter { it.isShown && it.getGlobalVisibleRect(Rect()) }
            .minByOrNull { abs(middle(it) - height) }
    }

    private fun middle(view: View): Int = IntArray(2).also { view.getLocationOnScreen(it) }[1] + view.height / 2
}
