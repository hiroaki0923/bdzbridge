package jp.hiroaki.bdbridge

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
import jp.hiroaki.bdbridge.bridge.AndroidBridge

class MainActivity : ComponentActivity() {
    // Swift's main queue, which nothing else runs on Android, run from the main thread while the app is on screen:
    // much of RecorderKit runs on Swift's main actor (core/Sources/AndroidBridge/MainQueue.swift). Each run takes
    // what has come since the last and returns at once; one comes every frame or so.
    private val mainThread = Handler(Looper.getMainLooper())
    private val mainQueue = object : Runnable {
        override fun run() {
            AndroidBridge.runWhatWaitsOnTheMainQueue()
            mainThread.postDelayed(this, 16)
        }
    }

    override fun onStart() {
        super.onStart()
        mainThread.post(mainQueue)
    }

    override fun onStop() {
        mainThread.removeCallbacks(mainQueue)
        super.onStop()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            RecBridgeTheme {
                val state: AppState = viewModel()
                if (state.recorder == null) DevicesScreen(state) else RecorderScreen(state)
            }
        }
    }
}
