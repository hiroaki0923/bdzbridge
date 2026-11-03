package jp.hiroaki.bdbridge.helper

import android.content.Context
import android.content.pm.PackageManager
import java.io.File

/** What the service and the screen share: the copies and the registered phones. Made once per process. */
object Helper {
    const val PORT = 8780
    const val API_VERSION = 1

    @Volatile private var snapshotsField: Snapshots? = null
    @Volatile private var devicesField: Devices? = null
    @Volatile var startedAt: Long? = null

    fun snapshots(context: Context): Snapshots {
        snapshotsField?.let { return it }
        synchronized(this) {
            snapshotsField?.let { return it }
            val app = context.applicationContext
            return Snapshots(File(app.filesDir, "snapshot"), app.contentResolver).also { snapshotsField = it }
        }
    }

    fun devices(context: Context): Devices {
        devicesField?.let { return it }
        synchronized(this) {
            devicesField?.let { return it }
            return Devices(File(context.applicationContext.filesDir, "devices.json")).also { devicesField = it }
        }
    }

    fun hasListingsPermission(context: Context): Boolean =
        context.checkSelfPermission("android.permission.READ_TV_LISTINGS") == PackageManager.PERMISSION_GRANTED

    fun tunerInstalled(context: Context): Boolean = try {
        context.packageManager.getPackageInfo(TvGuide.TUNER, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }
}
