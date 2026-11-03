package jp.hiroaki.bdbridge.helper

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Brings the helper up when the TV boots, and again after an update (an install stops the running
 * service), so that a phone finds it without anyone opening the screen.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> HelperService.start(context)
        }
    }
}
