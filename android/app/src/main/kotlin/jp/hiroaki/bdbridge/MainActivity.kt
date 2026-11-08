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

    // The model is told when the app comes into sight and goes out of it, as the iOS app tells it its scene's.
    override fun onStart() {
        super.onStart()
        RecBridge.onScreen(true)
    }

    override fun onStop() {
        RecBridge.onScreen(false)
        super.onStop()
    }
}
