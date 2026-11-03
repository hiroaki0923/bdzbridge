package jp.hiroaki.bdbridge.helper

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
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
 * with, and the phones let in so far. Built in code so that the helper has no library to carry.
 */
class MainActivity : Activity() {
    private val ui = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private lateinit var permissionButton: Button
    private lateinit var codeView: TextView
    private lateinit var codeButton: Button
    private lateinit var deviceList: LinearLayout
    private var showingCode = false
    private var lastRegistered: String? = null
    private val format = SimpleDateFormat("M/d HH:mm", Locale.JAPAN)

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
            setBackgroundColor(Color.rgb(16, 20, 28))
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

        setContentView(ScrollView(this).apply { addView(root) })
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
        permissionButton.visibility = if (granted) View.GONE else View.VISIBLE

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

        deviceList.removeAllViews()
        val list = devices.list()
        if (list.isEmpty()) {
            deviceList.addView(text("まだありません", 20f, dim = true))
        } else {
            for (d in list) {
                val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
                val used = d.lastUsedAt?.let { "最後の利用 " + format.format(Date(it)) } ?: "まだ使われていません"
                row.addView(text("${d.label}（${format.format(Date(d.createdAt))} に登録、$used）", 20f)
                    .apply { layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f) })
                row.addView(button("取り消す") { devices.revoke(d.id); render() })
                deviceList.addView(row)
            }
        }
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

    private fun button(label: String, onClick: () -> Unit): Button = Button(this).apply {
        text = label
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
        isFocusable = true
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
            .apply { topMargin = dp(8); bottomMargin = dp(8) }
    }

    private fun dp(v: Int): Int = (v * resources.displayMetrics.density).toInt()
}
