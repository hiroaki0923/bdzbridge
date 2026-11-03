package jp.hiroaki.bdbridge.helper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Process
import android.util.Log

/**
 * The resident part: listens on the LAN, watches the TV's guide store for changes and rebuilds the
 * copies in the background. Started at boot and from the screen; holds no wake lock, so it answers
 * while the TV keeps itself awake and goes quiet with it.
 */
class HelperService : Service() {
    private lateinit var worker: HandlerThread
    private lateinit var handler: Handler
    private var server: HttpServer? = null
    private var observer: ContentObserver? = null

    private val tick = object : Runnable {
        override fun run() {
            val snapshots = Helper.snapshots(this@HelperService)
            if (Helper.hasListingsPermission(this@HelperService) && snapshots.isDue()) {
                Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
                snapshots.rebuild()
            }
            handler.postDelayed(this, TICK_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Helper.startedAt = System.currentTimeMillis()
        startForeground(NOTIFICATION_ID, notification())
        worker = HandlerThread("helper-worker", Process.THREAD_PRIORITY_BACKGROUND).also { it.start() }
        handler = Handler(worker.looper)
        val api = Api(this)
        server = HttpServer(Helper.PORT) { api.handle(it) }.also { it.start() }
        observer = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                Helper.snapshots(this@HelperService).noteChange()
            }
        }.also {
            contentResolver.registerContentObserver(Uri.parse("content://android.media.tv/program"), true, it)
            contentResolver.registerContentObserver(Uri.parse("content://android.media.tv/channel"), true, it)
        }
        handler.post(tick)
        Log.i(TAG, "started on :${Helper.PORT}")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        observer?.let { contentResolver.unregisterContentObserver(it) }
        server?.stop()
        worker.quitSafely()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun notification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "RecBridge ヘルパー", NotificationManager.IMPORTANCE_MIN))
        return Notification.Builder(this, CHANNEL)
            .setContentTitle("RecBridge ヘルパー")
            .setContentText("番組表を iPhone に配っています")
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .build()
    }

    companion object {
        private const val TAG = "HelperService"
        private const val CHANNEL = "helper"
        private const val NOTIFICATION_ID = 1
        const val TICK_MS = 60 * 1000L

        fun start(context: Context) {
            context.startForegroundService(Intent(context, HelperService::class.java))
        }
    }
}
