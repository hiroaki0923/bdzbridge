package jp.hiroaki.bdbridge

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        RecBridge.open(applicationContext)
        enableEdgeToEdge()
        setContent { RecBridgeTheme { App() } }
    }

    // The model is told when the app comes into sight and goes out of it, as the iOS app tells it its scene's. Not
    // when the activity is only made again for a change of its configuration -- turned, or switched to dark --
    // which the app does not leave: the model would take it for a return, and connect again.
    override fun onStart() {
        super.onStart()
        if (madeAgain) madeAgain = false else RecBridge.onScreen(true)
    }

    override fun onStop() {
        if (isChangingConfigurations) madeAgain = true else RecBridge.onScreen(false)
        super.onStop()
    }

    private companion object {
        /** Set as the activity stops for a change of its configuration, for the one made after it. */
        var madeAgain = false
    }
}
