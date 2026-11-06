// Shared by sequenzy_flutter_geofences and @sequenzy/react-native-geofences.
// Edit mobile-sdks/geofence-bridge/android and run
// mobile-sdks/geofence-bridge/sync.sh; the copies in the plugins are generated.
package com.sequenzy.geofences.bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofenceStatusCodes
import com.google.android.gms.location.GeofencingEvent
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Finishes the broadcast when [work] is done or after a few seconds,
 * whichever comes first: a broadcast must finish within its deadline, and
 * everything the work needs to survive is already persisted.
 */
private fun BroadcastReceiver.finishWithin(work: (done: () -> Unit) -> Unit) {
    val pending = goAsync()
    val finished = AtomicBoolean(false)
    val done = { if (finished.compareAndSet(false, true)) pending.finish() }
    Handler(Looper.getMainLooper()).postDelayed({ done() }, 9_000)
    work(done)
}

/** Receives enter/exit from Play services, also when the app is not running. */
class SequenzyGeofenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val event = GeofencingEvent.fromIntent(intent) ?: return
        if (event.hasError()) {
            if (event.errorCode == GeofenceStatusCodes.GEOFENCE_NOT_AVAILABLE) {
                SequenzyGeofenceBridge.forgetRegistered(context)
            }
            Log.w("Sequenzy", "Geofence error ${event.errorCode}")
            return
        }
        val entered = when (event.geofenceTransition) {
            Geofence.GEOFENCE_TRANSITION_ENTER -> true
            Geofence.GEOFENCE_TRANSITION_EXIT -> false
            else -> return
        }
        val ids = event.triggeringGeofences.orEmpty().map { it.requestId }
        val at = event.triggeringLocation?.time?.takeIf { it > 0 } ?: System.currentTimeMillis()
        // The transition is stored first; sending and re-planning that take
        // longer than the broadcast allows continue while the process lives,
        // or on the next transition or launch.
        finishWithin { done -> SequenzyGeofenceBridge.handleTransition(context, ids, entered, at, done) }
    }
}

/** Re-registers geofences after a reboot or app update. */
class SequenzyGeofenceRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED ->
                finishWithin { done -> SequenzyGeofenceBridge.restore(context, done) }
        }
    }
}
