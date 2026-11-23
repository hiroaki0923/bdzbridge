package jp.hiroaki.bdbridge.helper

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Rect
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.util.TypedValue
import android.view.FocusFinder
import android.view.View
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
 * that edge in line with the text around it and never grows over its neighbour.
 */
internal fun Context.remoteButton(label: String, growFrom: Float = 0f, onClick: () -> Unit): Button = Button(this).apply {
    text = label
    setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
    isAllCaps = false
    // The theme's button lifts itself with a shadow when pressed; the fill says that here.
    stateListAnimator = null
    background = StateListDrawable().apply {
        addState(intArrayOf(android.R.attr.state_pressed), shape(PRESSED_FILL, PRESSED_FILL))
        addState(intArrayOf(android.R.attr.state_focused), shape(FOCUSED_FILL, FOCUSED_FILL))
        addState(intArrayOf(), shape(Color.TRANSPARENT, OUTLINE))
    }
    setTextColor(ColorStateList(
        arrayOf(intArrayOf(android.R.attr.state_pressed), intArrayOf(android.R.attr.state_focused), intArrayOf()),
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

/** Grows a button the remote has come to, and gives a button it has left its own size back. */
internal fun grow(view: View, focused: Boolean) {
    val scale = if (focused) GROWN else 1f
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
