import Flutter
import UIKit

/// Method channel between `SequenzyGeofences` in Dart and the native bridge.
/// Flutter registers plugins in `didFinishLaunching`, also when iOS launches
/// the app in the background for a region event, so the bridge is listening
/// before the event is delivered.
public class SequenzyFlutterGeofencesPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel

    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "sequenzy_flutter_geofences", binaryMessenger: registrar.messenger())
        let instance = SequenzyFlutterGeofencesPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        let bridge = SequenzyGeofenceBridge.shared
        bridge.onIdentityRejected = { [weak instance] in
            instance?.channel.invokeMethod("identityRejected", arguments: nil)
        }
        bridge.start()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let bridge = SequenzyGeofenceBridge.shared
        let arguments = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "configure":
            guard let apiBaseUrl = arguments["apiBaseUrl"] as? String,
                let companyId = arguments["companyId"] as? String,
                let publicKey = arguments["publicKey"] as? String,
                let appId = arguments["appId"] as? String
            else {
                return result(FlutterError(code: "invalid_arguments", message: "Missing configuration", details: nil))
            }
            bridge.configure(
                apiBaseUrl: apiBaseUrl, companyId: companyId, publicKey: publicKey, appId: appId,
                userAgent: arguments["userAgent"] as? String ?? "sequenzy-flutter-geofences")
            result(nil)
        case "setIdentity":
            result(
                bridge.setIdentity(
                    email: arguments["email"] as? String, identityToken: arguments["identityToken"] as? String,
                    externalId: arguments["externalId"] as? String))
        case "authorization":
            result(bridge.authorization)
        case "requestAuthorization":
            bridge.requestAuthorization { result($0) }
        case "enable":
            bridge.enable(maxRegions: arguments["maxRegions"] as? Int)
            result(nil)
        case "disable":
            bridge.disable()
            result(nil)
        case "refresh":
            bridge.refresh(force: true)
            result(nil)
        case "resume":
            // The bridge observes didBecomeActive itself.
            result(nil)
        case "status":
            result([
                "enabled": bridge.isEnabled,
                "authorization": bridge.authorization,
                "preciseLocation": bridge.hasPreciseLocation,
                "regionIds": bridge.registeredRegionIds,
                "queuedEvents": bridge.queuedEventCount,
                "maxRegions": bridge.maxRegions,
            ])
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
