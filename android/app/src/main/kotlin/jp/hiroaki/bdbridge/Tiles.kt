package jp.hiroaki.bdbridge

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import jp.hiroaki.bdbridge.bridge.TileDrawer
import java.io.FileOutputStream
import java.util.Locale

/**
 * Draws the logo tiles of the demo's stations, which the model seeds into the demo's guide: two characters, white on a
 * colour the station's place in its line-up picks. The tile is the iOS tile (`app/BDBridge/DemoTiles.swift`, 64 x 36
 * points) at three times the size; the colours are repeated from there.
 */
object Tiles : TileDrawer {
    // The six colours of `tileColours` in DemoTiles.swift, as 8-bit sRGB.
    private val colours = intArrayOf(
        Color.rgb(51, 112, 204), Color.rgb(41, 148, 107), Color.rgb(214, 92, 61),
        Color.rgb(115, 82, 179), Color.rgb(214, 153, 41), Color.rgb(61, 140, 158),
    )

    override fun draw(text: String, index: Long, path: String) {
        // Nothing may cross back into Swift: a tile not written is no logo, which is how the guide looked before.
        try {
            val bitmap = Bitmap.createBitmap(192, 108, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.drawRoundRect(RectF(0f, 0f, 192f, 108f), 18f, 18f,
                                 Paint(Paint.ANTI_ALIAS_FLAG).apply { color = colours[(index % colours.size).toInt()] })
            val ink = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = Color.WHITE
                textSize = 60f
                typeface = Typeface.DEFAULT_BOLD
                // Japanese shapes for the characters Chinese shares (教, 放, 送), whatever the device is set to.
                textLocale = Locale.JAPAN
            }
            val middle = (ink.descent() + ink.ascent()) / 2
            canvas.drawText(text, (192f - ink.measureText(text)) / 2, 54f - middle, ink)
            FileOutputStream(path).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        } catch (_: Throwable) {
        }
    }
}
