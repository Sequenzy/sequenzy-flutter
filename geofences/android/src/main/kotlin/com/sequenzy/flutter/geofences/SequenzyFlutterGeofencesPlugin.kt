package com.sequenzy.flutter.geofences

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.sequenzy.geofences.bridge.SequenzyGeofenceBridge
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Method channel between `SequenzyGeofences` in Dart and the native bridge.
 * Transitions are handled by the bridge's broadcast receiver, which needs no
 * Flutter engine.
 */
class SequenzyFlutterGeofencesPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var context: Context
    private var channel: MethodChannel? = null
    private var binding: ActivityPluginBinding? = null
    private var pendingAuthorization: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "sequenzy_flutter_geofences").also {
            it.setMethodCallHandler(this)
        }
        SequenzyGeofenceBridge.onIdentityRejected = {
            main.post { channel?.invokeMethod("identityRejected", null) }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        settlePendingAuthorization()
        channel?.setMethodCallHandler(null)
        channel = null
        SequenzyGeofenceBridge.onIdentityRejected = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val bridge = SequenzyGeofenceBridge
        when (call.method) {
            "configure" -> {
                val apiBaseUrl = call.argument<String>("apiBaseUrl")
                val companyId = call.argument<String>("companyId")
                val publicKey = call.argument<String>("publicKey")
                val appId = call.argument<String>("appId")
                if (apiBaseUrl == null || companyId == null || publicKey == null || appId == null) {
                    result.error("invalid_arguments", "Missing configuration", null)
                    return
                }
                bridge.configure(
                    context, apiBaseUrl, companyId, publicKey, appId,
                    call.argument<String>("userAgent") ?: "sequenzy-flutter-geofences",
                )
                result.success(null)
            }
            "setIdentity" -> bridge.setIdentity(context, call.argument("email"), call.argument("identityToken")) { rejected ->
                main.post { result.success(rejected) }
            }
            "authorization" -> result.success(bridge.authorization(context))
            "requestAuthorization" -> requestAuthorization(result)
            "enable" -> {
                bridge.enable(context, call.argument<Int>("maxRegions"))
                result.success(null)
            }
            "disable" -> {
                bridge.disable(context)
                result.success(null)
            }
            "refresh" -> {
                bridge.refresh(context, force = true)
                result.success(null)
            }
            "status" -> result.success(
                mapOf(
                    "enabled" to bridge.isEnabled(context),
                    "authorization" to bridge.authorization(context),
                    "preciseLocation" to bridge.hasPreciseLocation(context),
                    "regionIds" to bridge.registeredRegionIds(context),
                    "queuedEvents" to bridge.queuedEventCount(context),
                    "maxRegions" to bridge.maxRegions(context),
                ),
            )
            "resume" -> {
                bridge.resume(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // region Permissions

    /** Foreground location first, then background location in a second request (Android 10+). */
    private fun requestAuthorization(result: MethodChannel.Result) {
        val activity = binding?.activity
        val permissions = SequenzyGeofenceBridge.permissionsToRequest(context)
        if (activity == null || permissions.isEmpty() || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(SequenzyGeofenceBridge.authorization(context))
            return
        }
        pendingAuthorization?.success(SequenzyGeofenceBridge.authorization(context))
        pendingAuthorization = result
        ask(activity, permissions)
    }

    private fun ask(activity: Activity, permissions: Array<String>) {
        SequenzyGeofenceBridge.markPermissionAsked(context)
        // Runtime permissions start at Android 6; requestAuthorization answers
        // directly below that, so this is only reached on 6 and later.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            activity.requestPermissions(permissions, REQUEST_CODE)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingAuthorization ?: return true
        val granted = grantResults.isNotEmpty() && grantResults.any { it == PackageManager.PERMISSION_GRANTED }
        val next = SequenzyGeofenceBridge.permissionsToRequest(context)
        val activity = binding?.activity
        // The foreground step was just granted: ask for background location.
        if (granted && activity != null && next.isNotEmpty() && !next.contentEquals(permissions)) {
            ask(activity, next)
            return true
        }
        pendingAuthorization = null
        result.success(SequenzyGeofenceBridge.authorization(context))
        if (SequenzyGeofenceBridge.authorization(context) == "always") SequenzyGeofenceBridge.refresh(context, force = true)
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    // A pending request survives a configuration change: the answer arrives
    // at the recreated activity, which attaches again.
    override fun onDetachedFromActivityForConfigChanges() {
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        settlePendingAuthorization()
    }

    /** Answers a request whose activity went away, so Dart never waits forever. */
    private fun settlePendingAuthorization() {
        val result = pendingAuthorization ?: return
        pendingAuthorization = null
        result.success(SequenzyGeofenceBridge.authorization(context))
    }

    // endregion

    private companion object {
        const val REQUEST_CODE = 0x5e9f
    }
}
