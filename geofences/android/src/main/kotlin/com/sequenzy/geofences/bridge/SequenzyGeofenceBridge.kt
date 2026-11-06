// Shared by sequenzy_flutter_geofences and @sequenzy/react-native-geofences.
// Edit mobile-sdks/geofence-bridge/android and run
// mobile-sdks/geofence-bridge/sync.sh; the copies in the plugins are generated.
package com.sequenzy.geofences.bridge

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Region monitoring for the Flutter and React Native plugins. Android
 * delivers geofence transitions to a broadcast receiver without starting Dart
 * or JavaScript, so this object fetches the nearest geofences and reports
 * transitions itself, with the configuration and identity the plugin last
 * handed it.
 *
 * Work runs on one background thread, in order.
 */
object SequenzyGeofenceBridge {
    const val REFRESH_REGION_ID = "sequenzy.refresh"
    const val DEFAULT_MAX_REGIONS = 50
    private const val DEBOUNCE_MS = 60_000L
    private const val MIN_REFRESH_INTERVAL_MS = 60_000L
    private const val STALE_AFTER_MS = 6 * 60 * 60 * 1000L
    private const val MAX_QUEUED_EVENTS = 100
    private const val MAX_BATCH_SIZE = 20
    private const val MAX_EVENT_AGE_MS = 24 * 60 * 60 * 1000L
    private const val TAG = "Sequenzy"

    private const val PREFS = "sequenzy_geofence_bridge"
    private const val KEY_CONFIG = "config"
    private const val KEY_IDENTITY = "identity"
    private const val KEY_IDENTITY_REJECTED = "identityRejected"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_MAX_REGIONS = "maxRegions"
    private const val KEY_REGIONS = "regions"
    private const val KEY_LAST_FETCH = "lastFetch"
    private const val KEY_TRANSITIONS = "transitions"
    private const val KEY_QUEUE = "queue"
    private const val KEY_ASKED = "permissionAsked"

    /** Called when the server rejected the identity token, so the plugin can ask the app for a fresh one. */
    @Volatile
    var onIdentityRejected: (() -> Unit)? = null

    @Volatile
    var onLog: ((String) -> Unit)? = null

    private val executor = Executors.newSingleThreadExecutor()

    /** Guards the stored queue, which the receiver writes off the executor. */
    private val queueLock = Any()

    @Volatile
    private var lastRefreshRequest = 0L

    data class Region(val id: String, val latitude: Double, val longitude: Double, val radiusMeters: Double)

    // region Setup

    fun configure(context: Context, apiBaseUrl: String, companyId: String, publicKey: String, appId: String, userAgent: String) {
        val config = JSONObject()
            .put("apiBaseUrl", apiBaseUrl)
            .put("companyId", companyId)
            .put("publicKey", publicKey)
            .put("appId", appId)
            .put("userAgent", userAgent)
        prefs(context).edit().putString(KEY_CONFIG, config.toString()).apply()
    }

    /**
     * The signed-in contact. Another email (or null) drops everything recorded
     * for the previous one; a new token for the same email retries what was
     * held back. [done] receives true when this token was rejected earlier
     * (possibly while the plugin was not running), so the plugin should ask
     * the app for a fresh one.
     */
    fun setIdentity(context: Context, email: String?, identityToken: String?, done: ((Boolean) -> Unit)? = null) {
        val app = context.applicationContext
        executor.execute {
            val previous = identity(app)
            val next = if (!email.isNullOrEmpty() && !identityToken.isNullOrEmpty()) email to identityToken else null
            val editor = prefs(app).edit()
            if (next == null) {
                editor.remove(KEY_IDENTITY)
            } else {
                editor.putString(KEY_IDENTITY, JSONObject().put("email", next.first).put("identityToken", next.second).toString())
            }
            if (previous?.first != next?.first) {
                synchronized(queueLock) {
                    editor.remove(KEY_QUEUE).remove(KEY_TRANSITIONS).remove(KEY_LAST_FETCH)
                        .putBoolean(KEY_IDENTITY_REJECTED, false).commit()
                }
                apply(app, emptyList())
                done?.invoke(false)
                if (next != null) refreshLocked(app, force = true)
                return@execute
            }
            if (previous?.second != next?.second) {
                editor.putBoolean(KEY_IDENTITY_REJECTED, false).commit()
                done?.invoke(false)
                flushLocked(app)
                if (isStale(app)) refreshLocked(app, force = false)
            } else {
                editor.commit()
                done?.invoke(next != null && prefs(app).getBoolean(KEY_IDENTITY_REJECTED, false))
            }
        }
    }

    // endregion

    // region Permissions

    /** `notDetermined`, `denied`, `whenInUse` or `always`. */
    fun authorization(context: Context): String {
        if (!granted(context, Manifest.permission.ACCESS_FINE_LOCATION) &&
            !granted(context, Manifest.permission.ACCESS_COARSE_LOCATION)
        ) {
            return if (prefs(context).getBoolean(KEY_ASKED, false)) "denied" else "notDetermined"
        }
        val background = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
            granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        return if (background) "always" else "whenInUse"
    }

    fun hasPreciseLocation(context: Context): Boolean = granted(context, Manifest.permission.ACCESS_FINE_LOCATION)

    /**
     * The next permissions to ask for: foreground location first, then (on
     * Android 10 and later, in a separate request) background location.
     * Empty when everything is granted.
     */
    fun permissionsToRequest(context: Context): Array<String> {
        if (!hasPreciseLocation(context)) {
            return arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            !granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        ) {
            return arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        }
        return emptyArray()
    }

    fun markPermissionAsked(context: Context) {
        prefs(context).edit().putBoolean(KEY_ASKED, true).apply()
    }

    private fun canMonitor(context: Context): Boolean = authorization(context) == "always" && hasPreciseLocation(context)

    private fun granted(context: Context, permission: String): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    // endregion

    // region Enable and refresh

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_ENABLED, false)

    fun maxRegions(context: Context): Int = prefs(context).getInt(KEY_MAX_REGIONS, DEFAULT_MAX_REGIONS)

    /** Turns geofencing on and fetches the nearest geofences. */
    fun enable(context: Context, maxRegions: Int?) {
        val app = context.applicationContext
        val editor = prefs(app).edit().putBoolean(KEY_ENABLED, true)
        if (maxRegions != null) editor.putInt(KEY_MAX_REGIONS, maxRegions.coerceIn(2, 100))
        editor.apply()
        refresh(app, force = true)
    }

    /** Stops watching every Sequenzy region. Queued transitions are still sent. */
    fun disable(context: Context) {
        val app = context.applicationContext
        prefs(app).edit().putBoolean(KEY_ENABLED, false).apply()
        executor.execute {
            apply(app, emptyList())
            prefs(app).edit().remove(KEY_LAST_FETCH).apply()
        }
    }

    fun refresh(context: Context, force: Boolean = false, done: (() -> Unit)? = null) {
        val app = context.applicationContext
        executor.execute {
            try {
                refreshLocked(app, force)
            } finally {
                done?.invoke()
            }
        }
    }

    /** Refreshes when the last fetch is old and sends what is queued. Call when the app comes to the foreground. */
    fun resume(context: Context) {
        val app = context.applicationContext
        executor.execute {
            if (isEnabled(app) && isStale(app)) refreshLocked(app, force = false)
            flushLocked(app)
        }
    }

    /** Location was turned off: the system dropped every geofence. */
    internal fun forgetRegistered(context: Context) {
        val app = context.applicationContext
        executor.execute { prefs(app).edit().remove(KEY_REGIONS).remove(KEY_LAST_FETCH).commit() }
    }

    /** Re-registers the stored regions; the system clears them on reboot and app updates. */
    fun restore(context: Context, done: () -> Unit) {
        val app = context.applicationContext
        executor.execute {
            try {
                if (isEnabled(app)) {
                    val regions = registered(app)
                    // Stale until it succeeds, so an interrupted restore is retried.
                    val lastFetch = prefs(app).getLong(KEY_LAST_FETCH, 0)
                    prefs(app).edit().remove(KEY_REGIONS).remove(KEY_LAST_FETCH).commit()
                    if (apply(app, regions) && lastFetch > 0) {
                        prefs(app).edit().putLong(KEY_LAST_FETCH, lastFetch).commit()
                    }
                    if (isStale(app)) refreshLocked(app, force = false)
                }
                flushLocked(app)
            } finally {
                done()
            }
        }
    }

    fun registeredRegionIds(context: Context): List<String> = registered(context).map { it.id }

    fun queuedEventCount(context: Context): Int = queue(context).length()

    private fun isStale(context: Context): Boolean {
        val last = prefs(context).getLong(KEY_LAST_FETCH, 0)
        return last == 0L || System.currentTimeMillis() - last > STALE_AFTER_MS
    }

    @SuppressLint("MissingPermission")
    private fun refreshLocked(context: Context, force: Boolean) {
        if (!isEnabled(context)) return
        val now = System.currentTimeMillis()
        if (!force && now - lastRefreshRequest < MIN_REFRESH_INTERVAL_MS) return
        lastRefreshRequest = now
        if (!canMonitor(context)) {
            log("Geofencing needs fine and background location permission")
            return
        }
        val identity = identity(context) ?: return
        if (prefs(context).getBoolean(KEY_IDENTITY_REJECTED, false)) return
        val location = try {
            await(
                LocationServices.getFusedLocationProviderClient(context)
                    .getCurrentLocation(Priority.PRIORITY_BALANCED_POWER_ACCURACY, null),
            )
        } catch (error: Exception) {
            log("Location request failed: ${error.message}")
            null
        } ?: return
        val limit = (maxRegions(context) - 1).coerceIn(1, 99)
        val body = JSONObject()
            .put("email", identity.first)
            .put("identityToken", identity.second)
            .put("latitude", Math.round(location.latitude * 100) / 100.0)
            .put("longitude", Math.round(location.longitude * 100) / 100.0)
            .put("limit", limit)
        when (val result = post(context, "/api/v1/geofences/nearby", body)) {
            is Result.Ok -> {
                if (!isEnabled(context) || identity(context)?.first != identity.first) return
                val list = result.body.optJSONArray("geofences") ?: JSONArray()
                val planned = mutableListOf<Region>()
                for (index in 0 until list.length()) {
                    if (planned.size >= limit) break
                    regionFromJson(list.optJSONObject(index))?.let(planned::add)
                }
                val radius = result.body.optDouble("refreshRadiusMeters", Double.NaN)
                if (!radius.isNaN() && radius > 0) {
                    planned.add(Region(REFRESH_REGION_ID, location.latitude, location.longitude, radius))
                }
                // A plan Play services did not take is retried on the next foreground.
                if (apply(context, planned)) {
                    prefs(context).edit().putLong(KEY_LAST_FETCH, System.currentTimeMillis()).apply()
                } else {
                    prefs(context).edit().remove(KEY_LAST_FETCH).commit()
                }
            }
            Result.IdentityRejected -> identityRejected(context)
            is Result.Retry -> log("Could not fetch geofences: ${result.message}")
            is Result.Rejected -> log("Could not fetch geofences: ${result.message}")
        }
    }

    // endregion

    // region Regions

    private fun registered(context: Context): List<Region> {
        val raw = prefs(context).getString(KEY_REGIONS, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { regionFromJson(array.optJSONObject(it)) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun regionFromJson(json: JSONObject?): Region? {
        if (json == null) return null
        val id = json.optString("id").takeIf { it.isNotEmpty() } ?: return null
        val latitude = json.optDouble("latitude", Double.NaN)
        val longitude = json.optDouble("longitude", Double.NaN)
        val radius = json.optDouble("radiusMeters", Double.NaN)
        if (latitude.isNaN() || longitude.isNaN() || radius.isNaN()) return null
        return Region(id, latitude, longitude, radius)
    }

    /** Registers [planned]; returns whether Play services took all of it. */
    @SuppressLint("MissingPermission")
    private fun apply(context: Context, planned: List<Region>): Boolean {
        val client = LocationServices.getGeofencingClient(context)
        val current = registered(context)
        val next = planned.associateBy { it.id }
        val previous = current.associateBy { it.id }
        val remove = current.filter { next[it.id] != it }.map { it.id }
        val add = planned.filter { previous[it.id] != it }
        // Regions that could not be registered stay out of the stored list, so
        // the next plan adds them once permission is granted.
        val monitoring = canMonitor(context)
        val saved = if (monitoring) planned else planned.filter { previous[it.id] == it }
        try {
            if (remove.isNotEmpty()) await(client.removeGeofences(remove))
            if (add.isNotEmpty() && monitoring) {
                val request = GeofencingRequest.Builder()
                    // No enter for regions the device is already in: a re-plan
                    // must not report visits again.
                    .setInitialTrigger(0)
                    .addGeofences(
                        add.map { region ->
                            Geofence.Builder()
                                .setRequestId(region.id)
                                .setCircularRegion(region.latitude, region.longitude, region.radiusMeters.toFloat())
                                .setExpirationDuration(Geofence.NEVER_EXPIRE)
                                .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER or Geofence.GEOFENCE_TRANSITION_EXIT)
                                .build()
                        },
                    )
                    .build()
                await(client.addGeofences(request, pendingIntent(context)))
            }
            val array = JSONArray()
            saved.forEach { region ->
                array.put(
                    JSONObject()
                        .put("id", region.id)
                        .put("latitude", region.latitude)
                        .put("longitude", region.longitude)
                        .put("radiusMeters", region.radiusMeters),
                )
            }
            prefs(context).edit().putString(KEY_REGIONS, array.toString()).commit()
            return monitoring || add.isEmpty()
        } catch (error: Exception) {
            log("Could not update geofences: ${error.message}")
            return false
        }
    }

    internal fun pendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, SequenzyGeofenceReceiver::class.java)
        // The system fills in the triggering geofences, so it must be mutable.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
        return PendingIntent.getBroadcast(context, 0, intent, flags)
    }

    // endregion

    // region Transitions and the event queue

    internal fun handleTransition(
        context: Context,
        regionIds: List<String>,
        entered: Boolean,
        atMillis: Long,
        done: () -> Unit,
    ) {
        val app = context.applicationContext
        // Stored on the calling thread, not behind executor work that may be
        // waiting on location or the network: the receiver can be finished
        // (and the process killed) before the executor gets to it. Recorded
        // before any re-plan, which may drop these regions.
        val email = identity(app)?.first
        val known = registered(app).map { it.id }.toSet()
        val ids = regionIds.filter { it != REFRESH_REGION_ID && known.contains(it) }
        if (email != null && ids.isNotEmpty()) record(app, email, ids, if (entered) "enter" else "exit", atMillis)
        if (regionIds.contains(REFRESH_REGION_ID) && !entered) {
            // Stale until a fetch succeeds, so a failed one is retried on the
            // next transition, launch or foreground.
            prefs(app).edit().remove(KEY_LAST_FETCH).commit()
        }
        executor.execute {
            try {
                flushLocked(app)
                if (isEnabled(app) && isStale(app)) refreshLocked(app, force = false)
            } finally {
                done()
            }
        }
    }

    private fun record(
        context: Context,
        email: String,
        ids: List<String>,
        transition: String,
        atMillis: Long,
    ) = synchronized(queueLock) {
        val now = atMillis
        val recent = try {
            JSONObject(prefs(context).getString(KEY_TRANSITIONS, null) ?: "{}")
        } catch (_: Exception) {
            JSONObject()
        }
        val events = queue(context)
        for (id in ids) {
            val key = "$id:$transition"
            val last = recent.optLong(key, 0L)
            if (last != 0L && kotlin.math.abs(now - last) < DEBOUNCE_MS) continue
            recent.put(key, now)
            events.put(
                JSONObject()
                    .put("email", email)
                    .put("type", "geofence")
                    .put("name", "geofence")
                    .put("transition", transition)
                    .put("geofenceId", id)
                    .put("eventId", UUID.randomUUID().toString())
                    .put("occurredAt", isoFormat().format(Date(now)))
                    .put("properties", JSONObject()),
            )
        }
        val pruned = JSONObject()
        val wall = System.currentTimeMillis()
        recent.keys().forEach { key -> if (wall - recent.optLong(key) < MAX_EVENT_AGE_MS) pruned.put(key, recent.optLong(key)) }
        val kept = JSONArray()
        for (index in maxOf(0, events.length() - MAX_QUEUED_EVENTS) until events.length()) kept.put(events.get(index))
        prefs(context).edit().putString(KEY_TRANSITIONS, pruned.toString()).putString(KEY_QUEUE, kept.toString()).commit()
    }

    /** Sends queued transitions. Retryable failures keep them for the next transition or launch. */
    fun flush(context: Context, done: (() -> Unit)? = null) {
        val app = context.applicationContext
        executor.execute {
            try {
                flushLocked(app)
            } finally {
                done?.invoke()
            }
        }
    }

    private fun flushLocked(context: Context) {
        val identity = identity(context) ?: return
        if (prefs(context).getBoolean(KEY_IDENTITY_REJECTED, false)) return
        val cutoff = System.currentTimeMillis() - MAX_EVENT_AGE_MS
        while (true) {
            val fresh = JSONArray()
            synchronized(queueLock) {
                val all = queue(context)
                for (index in 0 until all.length()) {
                    val event = all.optJSONObject(index) ?: continue
                    val occurredAt = try {
                        isoFormat().parse(event.optString("occurredAt"))?.time ?: 0L
                    } catch (_: Exception) {
                        0L
                    }
                    if (event.optString("email") == identity.first && occurredAt > cutoff) fresh.put(event)
                }
                saveQueue(context, fresh)
            }
            if (fresh.length() == 0) return
            val batch = JSONArray()
            val ids = mutableSetOf<String>()
            for (index in 0 until minOf(MAX_BATCH_SIZE, fresh.length())) {
                val event = JSONObject(fresh.getJSONObject(index).toString())
                event.remove("email")
                ids.add(event.optString("eventId"))
                batch.put(event)
            }
            val body = JSONObject()
                .put("email", identity.first)
                .put("identityToken", identity.second)
                .put("events", batch)
            when (val result = post(context, "/api/v1/app-events", body)) {
                is Result.Ok, is Result.Rejected -> {
                    if (result is Result.Rejected) log("Dropped geofence events: ${result.message}")
                    synchronized(queueLock) {
                        val remaining = JSONArray()
                        val current = queue(context)
                        for (index in 0 until current.length()) {
                            val event = current.optJSONObject(index) ?: continue
                            if (!ids.contains(event.optString("eventId"))) remaining.put(event)
                        }
                        saveQueue(context, remaining)
                    }
                }
                Result.IdentityRejected -> {
                    identityRejected(context)
                    return
                }
                is Result.Retry -> {
                    log("Will retry geofence events: ${result.message}")
                    return
                }
            }
        }
    }

    private fun queue(context: Context): JSONArray = try {
        JSONArray(prefs(context).getString(KEY_QUEUE, null) ?: "[]")
    } catch (_: Exception) {
        JSONArray()
    }

    private fun saveQueue(context: Context, queue: JSONArray) {
        prefs(context).edit().putString(KEY_QUEUE, queue.toString()).commit()
    }

    private fun identityRejected(context: Context) {
        prefs(context).edit().putBoolean(KEY_IDENTITY_REJECTED, true).commit()
        log("The identity token was rejected; waiting for a fresh one")
        onIdentityRejected?.invoke()
    }

    // endregion

    // region HTTP

    private fun identity(context: Context): Pair<String, String>? {
        val raw = prefs(context).getString(KEY_IDENTITY, null) ?: return null
        return try {
            val json = JSONObject(raw)
            json.getString("email") to json.getString("identityToken")
        } catch (_: Exception) {
            null
        }
    }

    private sealed class Result {
        class Ok(val body: JSONObject) : Result()
        object IdentityRejected : Result()
        class Retry(val message: String) : Result()
        class Rejected(val message: String) : Result()
    }

    private fun post(context: Context, path: String, fields: JSONObject): Result {
        val config = try {
            JSONObject(prefs(context).getString(KEY_CONFIG, null) ?: return Result.Retry("not configured"))
        } catch (_: Exception) {
            return Result.Retry("not configured")
        }
        fields.put("companyId", config.optString("companyId"))
        fields.put("publicKey", config.optString("publicKey"))
        val base = config.optString("apiBaseUrl").trimEnd('/')
        return try {
            val connection = URL(base + path).openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.connectTimeout = 20_000
            connection.readTimeout = 20_000
            connection.doOutput = true
            connection.setRequestProperty("content-type", "application/json")
            connection.setRequestProperty("x-sequenzy-key", config.optString("publicKey"))
            connection.setRequestProperty("x-sequenzy-app-id", config.optString("appId"))
            connection.setRequestProperty("user-agent", config.optString("userAgent"))
            connection.outputStream.use { it.write(fields.toString().toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val stream = if (status >= 400) connection.errorStream else connection.inputStream
            val text = stream?.bufferedReader()?.use { it.readText() } ?: ""
            connection.disconnect()
            val json = try {
                JSONObject(text)
            } catch (_: Exception) {
                JSONObject()
            }
            when {
                status in 200..299 -> Result.Ok(json)
                (status == 401 || status == 403) && json.optString("code") == "invalid_web_tracking_identity" ->
                    Result.IdentityRejected
                status == 408 || status == 425 || status == 429 || status >= 500 -> Result.Retry("HTTP $status")
                else -> Result.Rejected("HTTP $status ${json.optString("error")}".trim())
            }
        } catch (error: Exception) {
            Result.Retry(error.message ?: "network error")
        }
    }

    private fun <T> await(task: Task<T>): T = Tasks.await(task, 30, TimeUnit.SECONDS)

    private fun isoFormat() = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun log(message: String) {
        onLog?.invoke(message) ?: Log.i(TAG, message)
    }

    // endregion
}
