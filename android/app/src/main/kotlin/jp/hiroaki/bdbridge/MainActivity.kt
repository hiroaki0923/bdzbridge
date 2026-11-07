package jp.hiroaki.bdbridge

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel

class MainActivity : ComponentActivity() {
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
