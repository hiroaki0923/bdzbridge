package jp.hiroaki.bdbridge.helper

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.graphics.Rect
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The screen on the TV: what the helper is doing, the permission it needs, the code a phone registers
 * with, and the phones let in so far. Built in code from the platform's own views (the button is in Screen.kt)
 * so that the helper has no library to carry.
 */
class MainActivity : Activity() {
    private val ui = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var permissionButton: Button
    private lateinit var codeView: TextView
    private lateinit var codeButton: Button
    private lateinit var noDevices: TextView
    private lateinit var deviceList: LinearLayout
    private val rows = ArrayList<DeviceRow>()
    private var showingCode = false
    private var lastRegistered: String? = null
    private val format = SimpleDateFormat("M/d HH:mm", Locale.JAPAN)

    /** A registered device's row, kept from one drawing to the next so that its button keeps the remote's focus. */
    private class DeviceRow(val id: String, val view: LinearLayout, val text: TextView, val revoke: Button)

    private val refresh = object : Runnable {
        override fun run() {
            render()
            ui.postDelayed(this, 2000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(64), dp(40), dp(64), dp(40))
            setBackgroundColor(SCREEN_BACKGROUND)
        }
        root.addView(text("RecBridge ヘルパー", 36f, bold = true))
        root.addView(text("テレビの番組表を、同じ家の中の iPhone の RecBridge に配ります。予約はしません。", 20f, dim = true))
        status = text("", 20f)
        root.addView(status)

        permissionButton = button("番組表の読み取りを許可する") {
            requestPermissions(arrayOf("android.permission.READ_TV_LISTINGS"), 1)
        }
        root.addView(permissionButton)

        root.addView(text("iPhone の登録", 26f, bold = true).apply { setPadding(0, dp(24), 0, dp(4)) })
        root.addView(text("RecBridge の設定でテレビを選び、ここに出る 6 桁の番号を入れてください。番号は 5 分で消えます。", 20f, dim = true))
        codeView = text("", 64f, bold = true).apply { gravity = Gravity.CENTER; letterSpacing = 0.3f }
        root.addView(codeView)
        codeButton = button("登録の番号を出す") {
            showingCode = !showingCode
            lastRegistered = null
            if (!showingCode) Helper.devices(this).hideCode()
            render()
        }
        root.addView(codeButton)

        root.addView(text("登録した iPhone", 26f, bold = true).apply { setPadding(0, dp(24), 0, dp(4)) })
        noDevices = text("まだありません", 20f, dim = true)
        root.addView(noDevices)
        deviceList = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        root.addView(deviceList)

        root.addView(text("しばらく使わないと Android が許可を取り消すことがあります。取り消さないように設定できます。", 20f, dim = true)
            .apply { setPadding(0, dp(24), 0, dp(4)) })
        root.addView(button("許可を取り消さない設定を開く") {
            try {
                startActivity(Intent(Intent.ACTION_AUTO_REVOKE_PERMISSIONS, Uri.fromParts("package", packageName, null)))
            } catch (e: ActivityNotFoundException) {
                status.text = "この設定画面はこのテレビにありません"
            }
        })

        // The page is moved through by the focus, never focused itself.
        setContentView(ScrollView(this).apply {
            isFocusable = false
            addView(root)
        })

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
            if (code == null) {
                codeView.text = "しばらく待ってから"
                codeView.textSize = 28f
            } else {
                codeView.text = code.substring(0, 3) + " " + code.substring(3)
                codeView.textSize = 64f
            }
            codeButton.text = "番号を消す"
        } else {
            codeView.text = lastRegistered?.let { "「$it」を登録しました" } ?: ""
            codeView.textSize = 24f
            codeButton.text = "登録の番号を出す"
        }

        showDevices(devices.list(), devices)
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
     * one's, else 登録の番号を出す; the page is scrolled to that row again once the rows have moved up into the
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
            row.text.text = "${d.label}（${format.format(Date(d.createdAt))} に登録、$used）"
        }
        noDevices.visibility = if (list.isEmpty()) View.VISIBLE else View.GONE
    }

    private fun deviceRow(d: Device, devices: Devices): DeviceRow {
        val text = text("", 20f).apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) }
        val revoke = button("取り消す", growFrom = 1f) { devices.revoke(d.id); render() }
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(text)
            addView(revoke)
        }
        val whole = { row.requestRectangleOnScreen(Rect(0, 0, row.width, row.height)) }
        revoke.setOnFocusChangeListener { v, focused ->
            grow(v, focused)
            // The page scrolls to the button the remote has moved to; this brings the rest of its row in with it.
            if (focused) whole()
        }
        // The focus is handed to this row while the row it leaves is still in the list, so the page first scrolls
        // by where the rows were; when they have moved up into the gap, or this row has grown a line, the page is
        // scrolled again by where it now is, before the frame is drawn, so that the button is not left partly off
        // the screen.
        row.addOnLayoutChangeListener { _, _, top, _, bottom, _, oldTop, _, oldBottom ->
            if (revoke.isFocused && (top != oldTop || bottom != oldBottom)) whole()
        }
        return DeviceRow(d.id, row, text, revoke)
    }

    private fun label(bt: String) = when (bt) {
        "td" -> "地上デジタル"; "bs" -> "BS"; "cs" -> "CS"; "bs4k" -> "BS4K"; "cs4k" -> "CS4K"; else -> bt
    }

    private fun text(s: String, size: Float, bold: Boolean = false, dim: Boolean = false): TextView = TextView(this).apply {
        text = s
        setTextSize(TypedValue.COMPLEX_UNIT_SP, size)
        setTextColor(if (dim) Color.rgb(170, 176, 186) else Color.WHITE)
        if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(0, dp(6), 0, dp(6))
    }

    private fun button(label: String, growFrom: Float = 0f, onClick: () -> Unit): Button =
        remoteButton(label, growFrom, onClick).apply {
            layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { topMargin = dp(8); bottomMargin = dp(8) }
        }
}
