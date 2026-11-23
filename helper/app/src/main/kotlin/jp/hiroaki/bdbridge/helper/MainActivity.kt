package jp.hiroaki.bdbridge.helper

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Rect
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Layout
import android.text.TextPaint
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.floor

/**
 * The screen on the TV, worked with its remote: on the left what the helper is doing and the permission it
 * needs, on the right the code a phone or a tablet registers with and the devices let in so far. It is laid out
 * for the 960 x 540 dp a television gives an app, inside the edge a television may crop, and does not scroll as a
 * whole; only the list of devices scrolls, when it is longer than its pane. Built in code from the platform's own
 * views (the parts are in Screen.kt) so that the helper has no library to carry.
 */
class MainActivity : Activity() {
    private val ui = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var permissionButton: Button
    private lateinit var codeView: TextView
    private lateinit var codeButton: Button
    private lateinit var noDevices: TextView
    private lateinit var devicePane: ScrollView
    private lateinit var deviceList: LinearLayout
    private val rows = ArrayList<DeviceRow>()
    private var showingCode = false
    private var lastRegistered: String? = null
    private val format = SimpleDateFormat("M/d HH:mm", Locale.JAPAN)

    /** A registered device's row, kept from one drawing to the next so that its button keeps the remote's focus. */
    private class DeviceRow(
        val id: String, val view: LinearLayout, val name: TextView, val details: TextView, val revoke: Button)

    private val refresh = object : Runnable {
        override fun run() {
            render()
            ui.postDelayed(this, 2000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val left = Column(this)
        left.addView(text("RecBridge ヘルパー", 28f, bold = true))
        left.addView(text("テレビの番組表を、同じ家の中の iPhone の RecBridge に配ります。予約はしません。", 18f, dim = true),
            below(2))
        status = text("", 16f)
        left.addView(status, below(8))
        permissionButton = remoteButton("番組表の読み取りを許可する") {
            requestPermissions(arrayOf("android.permission.READ_TV_LISTINGS"), 1)
        }
        left.addView(permissionButton, below(10, button = true))
        left.addView(text("しばらく使わないと Android が許可を取り消すことがあります。取り消さないように設定できます。", 18f, dim = true),
            below(10))
        left.addView(remoteButton("許可を取り消さない設定を開く") {
            try {
                startActivity(Intent(Intent.ACTION_AUTO_REVOKE_PERMISSIONS, Uri.fromParts("package", packageName, null)))
            } catch (e: ActivityNotFoundException) {
                status.text = "この設定画面はこのテレビにありません"
            }
        }, below(6, button = true))

        val right = Column(this)
        right.addView(text("iPhone の登録", 22f, bold = true))
        right.addView(text("RecBridge の設定でテレビを選び、ここに出る 6 桁の番号を入れてください。番号は 5 分で消えます。", 18f, dim = true),
            below(2))
        // A slot of the code's height at least, so that the button under it stays where it is whether the code, a
        // wait or the device just registered is shown, or nothing. On a television set to larger text it grows
        // rather than cutting what it shows.
        codeView = text("", 64f).apply {
            gravity = Gravity.CENTER_VERTICAL
            includeFontPadding = false
            minHeight = dp(76)
            ellipsize = TextUtils.TruncateAt.END
        }
        right.addView(codeView, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        codeButton = remoteButton("登録の番号を出す") {
            showingCode = !showingCode
            lastRegistered = null
            if (!showingCode) Helper.devices(this).hideCode()
            render()
        }
        right.addView(codeButton, below(0, button = true))
        right.addView(text("登録した iPhone", 22f, bold = true), below(14))
        noDevices = text("まだありません", 18f, dim = true)
        right.addView(noDevices, below(4))
        deviceList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        devicePane = ScrollView(this).apply {
            // The pane is moved through by the focus, never focused itself. A row cut by its top or bottom edge
            // fades out, which says there is more that way; the pane scrolls a focused row clear of the fade.
            isFocusable = false
            isVerticalFadingEdgeEnabled = true
            setFadingEdgeLength(dp(32))
            addView(deviceList)
        }
        right.addView(devicePane, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f).apply { topMargin = dp(4) })
        left.across = right
        right.across = left
        right.acrossKey = View.FOCUS_LEFT

        // The left column fits the screen with every line of the state shown at once; its scroll is only for a
        // television set to larger text, where the remote would otherwise reach a button off the screen.
        val leftPane = ScrollView(this).apply {
            isFocusable = false
            isVerticalFadingEdgeEnabled = true
            setFadingEdgeLength(dp(32))
            addView(left)
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            // Inside the 5 % at each edge that a television may crop.
            setPadding(dp(48), dp(27), dp(48), dp(27))
            setBackgroundColor(SCREEN_BACKGROUND)
            addView(leftPane, LinearLayout.LayoutParams(0, MATCH_PARENT, 57f))
            addView(right, LinearLayout.LayoutParams(0, MATCH_PARENT, 43f).apply { marginStart = dp(40) })
        }
        setContentView(root)

        // The remote starts on the button to use first. focusedByDefault is the same choice for the platform,
        // which gives the focus back to it when the window has none.
        val granted = Helper.hasListingsPermission(this)
        startOn(granted)
        (if (granted) codeButton else permissionButton).requestFocus()
    }

    override fun onResume() {
        super.onResume()
        HelperService.start(this)
        ui.post(refresh)
    }

    override fun onPause() {
        ui.removeCallbacks(refresh)
        super.onPause()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        render()
    }

    private fun render() {
        val granted = Helper.hasListingsPermission(this)
        val snapshots = Helper.snapshots(this)
        val lines = ArrayList<String>()
        lines.add("版 ${BuildConfig.VERSION_NAME}、ポート ${Helper.PORT}")
        lines.add(if (granted) "番組表の読み取り: 許可されています" else "番組表の読み取り: まだ許可されていません")
        if (!Helper.tunerInstalled(this)) lines.add("このテレビにはチューナーのアプリが見つかりません")
        val states = snapshots.typeStates()
        if (states.isEmpty()) {
            lines.add(if (snapshots.building) "番組表の写しを作っています" else if (granted) "番組表の写しはまだありません" else "")
        } else {
            for (bt in TvGuide.TYPES) {
                val s = states[bt] ?: continue
                lines.add("${label(bt)}: ${s.channels} 局、${s.programs} 番組、${format.format(Date(s.snapshotAt))} に写しました")
            }
        }
        snapshots.tunerLastWrite?.let { lines.add("テレビが番組表を最後に書いたのは ${format.format(Date(it))}") }
        snapshots.lastBuildError?.let { lines.add("写しを作れませんでした: $it") }
        status.text = lines.filter { it.isNotEmpty() }.joinToString("\n")
        // The permission's button goes once the permission is given; the remote, if it was on it, moves on to the
        // button to use next rather than to whichever the platform would pick.
        if (granted && permissionButton.isFocused) codeButton.requestFocus()
        permissionButton.visibility = if (granted) View.GONE else View.VISIBLE
        startOn(granted)

        val devices = Helper.devices(this)
        devices.takeRegistered()?.let { registered ->
            showingCode = false
            lastRegistered = registered.label
        }
        if (showingCode) {
            val code = devices.showCode()
            if (code == null) slot("しばらく待ってから", 28f, bold = true)
            else slot(code.substring(0, 3) + " " + code.substring(3), 64f, bold = true, code = true)
            codeButton.text = "番号を消す"
        } else {
            // A long name is cut at the end of the slot's second line; the list below has it whole.
            slot(lastRegistered?.let { "「$it」を登録しました" } ?: "", 18f)
            codeButton.text = "登録の番号を出す"
        }

        showDevices(devices.list(), devices)
    }

    /**
     * What the code's slot shows: the code, the largest thing on the screen, or a line in its place. The code is
     * never broken in two: it is one line, and where larger text would make it wider than the column, it is drawn
     * just small enough to fit.
     */
    private fun slot(s: String, sp: Float, bold: Boolean = false, code: Boolean = false) {
        codeView.text = s
        codeView.setTypeface(null, if (bold) Typeface.BOLD else Typeface.NORMAL)
        codeView.letterSpacing = if (code) 0.15f else 0f
        // Set only when it changes: the view asks for a layout whenever it is set, even to what it was.
        val lines = if (code) 1 else 2
        if (codeView.maxLines != lines) codeView.maxLines = lines
        var size = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, resources.displayMetrics)
        val room = codeView.width - codeView.totalPaddingLeft - codeView.totalPaddingRight
        if (code && room > 0) {
            // Measured as the view lays it out, letter spacing and all.
            val paint = TextPaint(codeView.paint)
            val wide = { px: Float -> Layout.getDesiredWidth(s, paint.apply { textSize = px }) }
            if (wide(size) > room) size = floor(size * room / wide(size))
            while (wide(size) > room) size -= 1f
        }
        codeView.setTextSize(TypedValue.COMPLEX_UNIT_PX, size)
    }

    /** The button the remote starts on, for the platform: the permission's while it is not given, else the code's. */
    private fun startOn(granted: Boolean) {
        permissionButton.isFocusedByDefault = !granted
        codeButton.isFocusedByDefault = granted
    }

    /**
     * Brings the rows in step with the registered devices without throwing away the ones still listed, so that a
     * 取り消す the remote is on keeps the focus while the screen is drawn again every two seconds. The helper's
     * list only grows at its end and loses a device by a revoke, so a kept row never changes place. A row that
     * goes while the remote is on it hands the focus on first: to the next row's 取り消す, else the previous
     * one's, else 登録の番号を出す; the pane is scrolled to that row again once the rows have moved up into the
     * gap (deviceRow).
     */
    private fun showDevices(list: List<Device>, devices: Devices) {
        val listed = list.map { it.id }.toSet()
        val kept = rows.filter { it.id in listed }
        for ((i, row) in rows.withIndex()) {
            if (row.id in listed) continue
            if (row.revoke.isFocused) {
                val next = rows.drop(i + 1).firstOrNull { it in kept } ?: rows.take(i).lastOrNull { it in kept }
                (next?.revoke ?: codeButton).requestFocus()
            }
            deviceList.removeView(row.view)
        }
        rows.retainAll(kept)
        for ((i, d) in list.withIndex()) {
            val row = rows.getOrNull(i)?.takeIf { it.id == d.id }
                ?: deviceRow(d, devices).also { rows.add(i, it); deviceList.addView(it.view, i) }
            val used = d.lastUsedAt?.let { "最後の利用 " + format.format(Date(it)) } ?: "まだ使われていません"
            row.name.text = d.label
            // Broken after the 、 so that each half is a line of its own, the dates in the same place on every row.
            row.details.text = "（${format.format(Date(d.createdAt))} に登録、\n$used）"
        }
        noDevices.visibility = if (list.isEmpty()) View.VISIBLE else View.GONE
    }

    private fun deviceRow(d: Device, devices: Devices): DeviceRow {
        // The name on a line of its own, wrapping rather than being cut: it is what is read before a revoke. Under
        // it, smaller and dimmer, when the device was registered and last used.
        val name = text("", 18f)
        val details = text("", 16f, dim = true)
        val words = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(name)
            addView(details)
        }
        val revoke = remoteButton("取り消す", growFrom = 1f) { devices.revoke(d.id); render() }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(6), 0, dp(6))
            addView(words, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { marginEnd = dp(20) })
            addView(revoke, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        }
        val whole = { row.requestRectangleOnScreen(Rect(0, 0, row.width, row.height)) }
        revoke.setOnFocusChangeListener { v, focused ->
            grow(v, focused)
            // The pane scrolls to the button the remote has moved to; this brings the rest of its row in with it.
            if (focused) whole()
        }
        // The focus is handed to this row while the row it leaves is still in the list, so the pane first scrolls
        // by where the rows were; when they have moved up into the gap, or this row has grown a line, the pane is
        // scrolled again by where it now is, before the frame is drawn, so that the button is not left under the
        // pane's fading edge. The scroll begun by where the rows were is stopped first: a scroll of nothing ends
        // it, and makes the two after it at once rather than eased. Then the row is brought in, and then the
        // button itself, so that where a row is taller than the pane (larger text) the button still ends whole.
        row.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            if (revoke.isFocused && (top != oldTop || bottom != oldBottom)) {
                devicePane.smoothScrollBy(0, 0)
                whole()
                inView(revoke)
            }
        }
        return DeviceRow(d.id, row, name, details, revoke)
    }

    private fun label(bt: String) = when (bt) {
        "td" -> "地上デジタル"; "bs" -> "BS"; "cs" -> "CS"; "bs4k" -> "BS4K"; "cs4k" -> "CS4K"; else -> bt
    }

    /** A column's layout for a view with `top` dp above it; a button keeps its own width and room under it to grow. */
    private fun below(top: Int, button: Boolean = false) =
        LinearLayout.LayoutParams(if (button) WRAP_CONTENT else MATCH_PARENT, WRAP_CONTENT).apply {
            topMargin = dp(top)
            if (button) bottomMargin = dp(4)
        }
}
