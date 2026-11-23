package jp.hiroaki.bdbridge.helper

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.util.TypedValue
import android.view.View
import android.widget.Button

/*
 * The parts the helper's screen is made of. The screen is seen from a sofa and worked with the television's
 * remote only, so what matters most is that the button the remote is on can be told at a glance from three
 * metres.
 */

internal val SCREEN_BACKGROUND = Color.rgb(16, 20, 28)
internal val TEXT_BRIGHT = Color.WHITE
private val OUTLINE = Color.rgb(128, 136, 150)
private val FOCUSED_FILL = Color.rgb(246, 248, 251)
private val PRESSED_FILL = Color.rgb(188, 198, 212)

/** How much larger the button the remote is on grows, and how quickly. */
private const val GROWN = 1.08f
private const val GROW_MS = 120L

internal fun Context.dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()

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
    addOnLayoutChangeListener { v, left, top, right, bottom, _, _, _, _ ->
        v.pivotX = (right - left) * growFrom
        v.pivotY = (bottom - top) / 2f
    }
    setOnFocusChangeListener { v, focused -> grow(v, focused) }
}

/**
 * Grows a button the remote has come to, and gives a button it has left its own size back. A pane that scrolls
 * brings in the room the button grows into as well as the button itself, so that its edge is never cut.
 */
internal fun grow(view: View, focused: Boolean) {
    val scale = if (focused) GROWN else 1f
    view.animate().scaleX(scale).scaleY(scale).setDuration(GROW_MS).start()
    if (focused) {
        val room = (view.height * (GROWN - 1f)).toInt()
        view.requestRectangleOnScreen(Rect(0, -room, view.width, view.height + room))
    }
}

private fun Context.shape(fill: Int, stroke: Int): Drawable = GradientDrawable().apply {
    cornerRadius = dp(8).toFloat()
    setColor(fill)
    setStroke(dp(2), stroke)
}
