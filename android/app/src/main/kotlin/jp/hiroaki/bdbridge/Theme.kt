package jp.hiroaki.bdbridge

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList

/**
 * Material 3 as Android draws it: the colours taken from the wallpaper where the system offers them (Android 12 and
 * later), the default scheme elsewhere, light or dark as the device is set.
 */
@Composable
fun RecBridgeTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val context = LocalContext.current
    val colors = when {
        Build.VERSION.SDK_INT >= 31 && dark -> dynamicDarkColorScheme(context)
        Build.VERSION.SDK_INT >= 31 -> dynamicLightColorScheme(context)
        dark -> darkColorScheme()
        else -> lightColorScheme()
    }
    MaterialTheme(colorScheme = colors, typography = inJapanese(Typography())) {
        androidx.compose.runtime.CompositionLocalProvider(LocalMarks provides if (dark) darkMarks else lightMarks) {
            content()
        }
    }
}

/**
 * Every style of the app's text marked as Japanese. Android chooses the shapes of the characters Chinese and Japanese
 * share by the language a text is in, and takes the device's when nothing says: on a device set to English or
 * Chinese, 直 came out in its Chinese shape. Everything the app says is Japanese, whatever the device is set to.
 */
private fun inJapanese(typography: Typography): Typography {
    val japanese = LocaleList(Locale("ja-JP"))
    fun TextStyle.japanese() = copy(localeList = japanese)
    return typography.copy(
        displayLarge = typography.displayLarge.japanese(), displayMedium = typography.displayMedium.japanese(),
        displaySmall = typography.displaySmall.japanese(), headlineLarge = typography.headlineLarge.japanese(),
        headlineMedium = typography.headlineMedium.japanese(), headlineSmall = typography.headlineSmall.japanese(),
        titleLarge = typography.titleLarge.japanese(), titleMedium = typography.titleMedium.japanese(),
        titleSmall = typography.titleSmall.japanese(), bodyLarge = typography.bodyLarge.japanese(),
        bodyMedium = typography.bodyMedium.japanese(), bodySmall = typography.bodySmall.japanese(),
        labelLarge = typography.labelLarge.japanese(), labelMedium = typography.labelMedium.japanese(),
        labelSmall = typography.labelSmall.japanese(),
    )
}

/**
 * The colours of the marks on a row, which say the same as the iOS app's: orange for a reservation and for one
 * waiting to be sent, red for one recording now or refused. The orange is not among Material's roles, so it is the
 * app's own, a container and its text for light and for dark.
 */
@Immutable
data class Marks(val reserved: Color, val onReserved: Color)

private val lightMarks = Marks(reserved = Color(0xFFFFDCC0), onReserved = Color(0xFF6B3A00))
private val darkMarks = Marks(reserved = Color(0xFF5C3A12), onReserved = Color(0xFFFFDCC0))

val LocalMarks = staticCompositionLocalOf { lightMarks }
