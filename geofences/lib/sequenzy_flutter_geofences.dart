/// Geofencing for the Sequenzy Flutter SDK.
///
/// ```dart
/// Sequenzy.configure(SequenzyConfig(...));
/// await SequenzyGeofences.start();
/// // once the user agreed to location-based messages
/// await SequenzyGeofences.requestAuthorization();
/// await SequenzyGeofences.enable();
/// ```
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:sequenzy_flutter/sequenzy_flutter.dart';

/// Location access as the OS reports it. Geofencing needs [always].
enum GeofenceAuthorization { notDetermined, denied, whenInUse, always }

class GeofenceStatus {
  const GeofenceStatus({
    required this.enabled,
    required this.authorization,
    required this.preciseLocation,
    required this.regionIds,
    required this.queuedEvents,
    required this.maxRegions,
  });

  final bool enabled;
  final GeofenceAuthorization authorization;
  final bool preciseLocation;

  /// Regions registered with the OS, including the refresh region.
  final List<String> regionIds;

  /// Transitions recorded on the device and not yet accepted by Sequenzy.
  final int queuedEvents;
  final int maxRegions;

  bool get isMonitoring => enabled && authorization == GeofenceAuthorization.always && preciseLocation;
}

/// Watches the nearest of your geofences with the OS and reports when the
/// signed-in contact enters or leaves one, also while the app is in the
/// background or not running. Native code does the reporting, with the
/// configuration and identity this class hands it.
abstract final class SequenzyGeofences {
  static const _channel = MethodChannel('sequenzy_flutter_geofences');

  /// Tokens that expire sooner are replaced through the identity token
  /// provider, since native code may report while Dart is not running.
  static const refreshTokenWithin = Duration(days: 3);

  static StreamSubscription<SequenzyIdentityEvent>? _identity;
  static AppLifecycleListener? _lifecycle;
  static Future<void>? _started;
  static Future<void> _syncing = Future.value();

  /// Hands the Sequenzy configuration and the signed-in contact to the native
  /// side and keeps them current. Call after `Sequenzy.configure` on every
  /// launch.
  static Future<void> start() => _started ??= _start();

  static Future<void> _start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'identityRejected') await _sync(refreshToken: true);
    });
    _identity = Sequenzy.identityEvents.listen((_) => unawaited(_sync().catchError(_ignore)));
    _lifecycle = AppLifecycleListener(onResume: () {
      unawaited(_sync().then((_) => _channel.invokeMethod<void>('resume')).catchError(_ignore));
    });
    try {
      await _sync();
    } catch (_) {
      // A later start (after Sequenzy.configure) begins again.
      await stop();
      rethrow;
    }
  }

  /// Asks for location access: "While using the app" first, then "Always"
  /// (on Android 10 and later this opens the settings page).
  static Future<GeofenceAuthorization> requestAuthorization() async =>
      _authorization(await _channel.invokeMethod<String>('requestAuthorization'));

  static Future<GeofenceAuthorization> authorization() async =>
      _authorization(await _channel.invokeMethod<String>('authorization'));

  /// Turns geofencing on and fetches the nearest geofences. [maxRegions]
  /// caps the regions Sequenzy registers (iOS 20, Android 50 by default);
  /// lower it when the app monitors regions of its own.
  static Future<void> enable({int? maxRegions}) async {
    await start();
    await _channel.invokeMethod<void>('enable', {if (maxRegions != null) 'maxRegions': maxRegions});
  }

  /// Turns geofencing off and stops watching every Sequenzy region. Call when
  /// the user withdraws consent.
  static Future<void> disable() => _channel.invokeMethod<void>('disable');

  /// Fetches the nearest geofences for the current position now.
  static Future<void> refresh() => _channel.invokeMethod<void>('refresh');

  static Future<GeofenceStatus> status() async {
    final map = await _channel.invokeMapMethod<String, Object?>('status') ?? const {};
    return GeofenceStatus(
      enabled: map['enabled'] == true,
      authorization: _authorization(map['authorization'] as String?),
      preciseLocation: map['preciseLocation'] == true,
      regionIds: (map['regionIds'] as List?)?.whereType<String>().toList() ?? const [],
      queuedEvents: (map['queuedEvents'] as num?)?.toInt() ?? 0,
      maxRegions: (map['maxRegions'] as num?)?.toInt() ?? 0,
    );
  }

  /// For tests: forget [start].
  @visibleForTesting
  static Future<void> stop() async {
    await _identity?.cancel();
    _identity = null;
    _lifecycle?.dispose();
    _lifecycle = null;
    _started = null;
    _syncing = Future.value();
    _channel.setMethodCallHandler(null);
  }

  static void _ignore(Object error) {}

  /// One at a time, so an older identity never overwrites a newer one.
  static Future<void> _sync({bool refreshToken = false}) {
    final next = _syncing.then((_) => _syncNow(refreshToken: refreshToken));
    _syncing = next.catchError(_ignore);
    return next;
  }

  static Future<void> _syncNow({required bool refreshToken}) async {
    final client = Sequenzy.client;
    if (client == null) {
      throw SequenzyException('Call Sequenzy.configure(...) first', 'not_identified');
    }
    final config = client.config;
    await _channel.invokeMethod<void>('configure', {
      'apiBaseUrl': config.apiBaseUrl,
      'companyId': config.companyId,
      'publicKey': config.publicKey,
      'appId': config.appId,
      'userAgent': 'sequenzy-flutter-geofences/$sequenzySdkVersion',
    });
    var credentials = await client.identityCredentials(refresh: refreshToken);
    if (credentials != null && !refreshToken && _expiresSoon(credentials.identityToken)) {
      credentials = await client.identityCredentials(refresh: true) ?? credentials;
    }
    final rejected = await _setIdentity(credentials);
    // The native side saw this token rejected while Dart was not running.
    if (rejected && !refreshToken && credentials != null) {
      final fresh = await client.identityCredentials(refresh: true);
      if (fresh != null && fresh.identityToken != credentials.identityToken) await _setIdentity(fresh);
    }
  }

  /// Whether the native side holds this token as rejected.
  static Future<bool> _setIdentity(({String email, String identityToken})? credentials) async =>
      await _channel.invokeMethod<bool>('setIdentity', {
        'email': credentials?.email,
        'identityToken': credentials?.identityToken,
      }) ==
      true;

  static bool _expiresSoon(String token) {
    final expiresAt = identityTokenExpiry(token);
    return expiresAt != null && expiresAt.isBefore(DateTime.now().add(refreshTokenWithin));
  }

  /// When a `seq_wid_` identity token expires, or null when it cannot be read.
  @visibleForTesting
  static DateTime? identityTokenExpiry(String token) {
    if (!token.startsWith('seq_wid_')) return null;
    final parts = token.substring(8).split('.');
    if (parts.length != 2) return null;
    try {
      final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))));
      final expiresAt = claims is Map ? claims['expiresAt'] : null;
      return expiresAt is num ? DateTime.fromMillisecondsSinceEpoch(expiresAt.toInt(), isUtc: true) : null;
    } catch (_) {
      return null;
    }
  }

  static GeofenceAuthorization _authorization(String? value) => switch (value) {
        'always' => GeofenceAuthorization.always,
        'whenInUse' => GeofenceAuthorization.whenInUse,
        'notDetermined' => GeofenceAuthorization.notDetermined,
        _ => GeofenceAuthorization.denied,
      };
}
