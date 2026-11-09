import 'dart:async';

import 'package:url_launcher/url_launcher.dart';

import 'client.dart';
import 'geofences.dart';
import 'live_updates.dart';
import 'models.dart';
import 'storage.dart';

/// `identified` after identify completes, `reset` after reset.
enum SequenzyIdentityEvent { identified, reset }

/// The Sequenzy SDK for Flutter.
///
/// ```dart
/// Sequenzy.configure(SequenzyConfig(
///   publicKey: 'seq_pk_...', companyId: '...', appId: 'com.example.app',
///   platform: Platform.isIOS ? 'ios' : 'android',
/// ));
/// await Sequenzy.identify(user.email, identityToken: tokenFromYourBackend);
/// Sequenzy.track('workout_completed', {'minutes': 30});
/// ```
class Sequenzy {
  Sequenzy._();

  static SequenzyClient? _client;
  static final _events = StreamController<SequenzyIdentityEvent>.broadcast();

  /// How the SDK opens URLs. Defaults to url_launcher.
  static Future<void> Function(String url) urlOpener = _launch;

  static SequenzyClient? get client => _client;

  static Stream<SequenzyIdentityEvent> get identityEvents => _events.stream;

  static SequenzyClient configure(SequenzyConfig config, {SequenzyStore? store, SequenzyClient? client}) {
    return _client ??= client ?? SequenzyClient(config, store: store);
  }

  /// For tests: forget the configured client.
  static void unconfigure() {
    _client = null;
    urlOpener = _launch;
    settingsOpener = _openAppSettings;
  }

  static SequenzyClient _require() {
    final client = _client;
    if (client == null) {
      throw SequenzyException('Call Sequenzy.configure(...) first', 'not_identified');
    }
    return client;
  }

  /// Links this installation to [email]. Returns false (and logs why) when
  /// the email is not valid; listeners only hear about successful identifies.
  static Future<bool> identify(String email, {String? identityToken}) async {
    final client = _require();
    await client.identify(email, identityToken: identityToken);
    final identified = await client.email() == email.trim().toLowerCase();
    if (identified) _events.add(SequenzyIdentityEvent.identified);
    return identified;
  }

  /// Links this installation to the contact with your own user ID, for users
  /// without an email. Pass [email] too when you have it; the identity token
  /// must be minted for exactly these identifiers. Returns false (and logs
  /// why) when the ID or email is not valid.
  static Future<bool> identifyUser(String externalId, {String? email, String? identityToken}) async {
    final client = _require();
    await client.identifyUser(externalId, email: email, identityToken: identityToken);
    final expectedEmail = email == null || email.trim().isEmpty ? null : email.trim().toLowerCase();
    final identified = await client.externalId() == externalId.trim() && await client.email() == expectedEmail;
    if (identified) _events.add(SequenzyIdentityEvent.identified);
    return identified;
  }

  static Future<void> reset() async {
    await _require().reset();
    _events.add(SequenzyIdentityEvent.reset);
  }

  static Future<void> track(String name, [Map<String, Object?> properties = const {}]) =>
      _require().track(name, properties);

  /// Records a screen view as the built-in "Screen Viewed" event.
  static Future<void> screen(String name, [Map<String, Object?> properties = const {}]) =>
      _require().screen(name, properties);

  static Future<void> viewedProduct(CommerceProduct product) => _require().viewedProduct(product);

  static Future<void> addedToCart(CommerceCartLine line) => _require().addedToCart(line);

  static Future<void> removedFromCart(CommerceCartLine line) => _require().removedFromCart(line);

  static Future<void> viewedCart(CommerceCart cart) => _require().viewedCart(cart);

  static Future<void> viewedCollection(CommerceCollection collection) => _require().viewedCollection(collection);

  static Future<void> searched(String query) => _require().searched(query);

  /// Name and custom attributes of the signed-in contact.
  static Future<void> setProfile(ProfileUpdate update) => _require().setProfile(update);

  /// Newsletter or waitlist signup through a published form.
  static Future<SubscribeResult> subscribe(SubscribeRequest request) => _require().subscribe(request);

  static Future<void> flush() => _require().flush();

  /// Registers the APNs or FCM token from Firebase Messaging (`getToken()` on
  /// Android, `getAPNSToken()` on iOS) and `onTokenRefresh`.
  static Future<void> setPushToken(String token) => _require().setPushToken(token);

  /// iOS Live Activities: pass the ActivityKit tokens your Swift code (or a
  /// plugin such as live_activities) receives, so your backend can start,
  /// update and end activities through Sequenzy.
  static Future<void> registerLiveActivityToken(LiveActivityToken token) =>
      _require().registerLiveActivityToken(token);

  /// Call when an activity ends or is dismissed, with its update token.
  static Future<void> liveActivityEnded(String token) => _require().liveActivityEnded(token);

  /// Android Live Updates: reports this device can start activities of
  /// [activityType] (the same name as your iOS ActivityAttributes type, so one
  /// backend call reaches both). Call at launch for each type you draw.
  static Future<void> observeLiveUpdates(String activityType) => _require().observeLiveUpdates(activityType);

  /// Android Live Updates: pass `RemoteMessage.data` from firebase_messaging's
  /// `onMessage` and `onBackgroundMessage`. Returns what to show (post or
  /// update the notification for `activityId`), or null for other messages.
  static Future<LiveUpdateDecision?> handleLiveUpdate(Map<dynamic, dynamic> data, {bool canShow = true}) =>
      _require().handleLiveUpdate(data, canShow: canShow);

  /// Android Live Updates: starts an activity from the app; your backend
  /// updates and ends it by [activityId].
  static Future<LiveUpdateDecision> startLiveUpdate({
    required String activityType,
    required String activityId,
    Map<String, Object?> attributes = const {},
    Map<String, Object?> contentState = const {},
  }) =>
      _require().startLiveUpdate(
          activityType: activityType, activityId: activityId, attributes: attributes, contentState: contentState);

  /// Android Live Updates: updates a running activity from the app.
  static Future<LiveUpdateDecision> updateLiveUpdate(String activityId, Map<String, Object?> contentState) =>
      _require().updateLiveUpdate(activityId, contentState);

  /// Android Live Updates: ends a running activity from the app.
  static Future<LiveUpdateDecision> endLiveUpdate(String activityId,
          {Map<String, Object?>? contentState, DateTime? dismissAt}) =>
      _require().endLiveUpdate(activityId, contentState: contentState, dismissAt: dismissAt);

  /// Android Live Updates: call when the person swipes one away.
  static Future<void> liveUpdateDismissed(String activityId) => _require().liveUpdateDismissed(activityId);

  /// Android Live Updates this device shows now.
  static Future<List<LiveUpdateActivity>> liveUpdates() => _require().liveUpdates();

  /// Call when the user opens a notification (`FirebaseMessaging.onMessageOpenedApp`,
  /// `getInitialMessage`) with `message.data`. Reports the click and opens the push URL.
  /// Returns false for other senders.
  static Future<bool> handleNotificationOpened(Map<String, dynamic> data, {bool openUrl = true}) async {
    final payload = PushPayload.fromData(data);
    if (payload == null) return false;
    await _require().reportPush('clicked', payload);
    if (openUrl && payload.url != null) await urlOpener(payload.url!);
    return true;
  }

  /// Call when a notification arrives (`FirebaseMessaging.onMessage`).
  static Future<bool> handleNotificationReceived(Map<String, dynamic> data) async {
    final payload = PushPayload.fromData(data);
    if (payload == null) return false;
    await _require().reportPush('delivered', payload);
    return true;
  }

  /// The signed-in contact's email, or null (also for a user identified by
  /// external ID only).
  static Future<String?> identifiedEmail() => _require().email();

  /// One string per signed-in contact (the external ID or the email), or
  /// null while anonymous. Geofence plugins only watch places while it is set.
  static Future<String?> identifiedContact() => _require().contactKey();

  /// The nearest active geofences around a position. Usually called by the
  /// `sequenzy_flutter_geofences` plugin rather than the app.
  static Future<NearbyGeofences> fetchNearbyGeofences(double latitude, double longitude, {int? limit}) =>
      _require().fetchNearbyGeofences(
          latitude, longitude, limit ?? Geofencing.fetchLimit(Geofencing.defaultMaxRegionsIOS));

  /// Reports an enter or exit for a geofence your own region monitoring saw.
  static Future<bool> trackGeofenceTransition(String geofenceId, GeofenceTransition transition, {DateTime? at}) =>
      _require().trackGeofenceTransition(geofenceId, transition, at: at);

  /// Open in-app messages, for apps that present them themselves. Custom HTML
  /// messages are included only with [includeHtml].
  static Future<List<InAppMessage>> fetchMessages({bool includeHtml = false}) => _require().fetchFeed(
        kind: 'message',
        formats: includeHtml ? const ['modal', 'banner', 'fullscreen', 'html'] : null,
      );

  static Future<List<InAppMessage>> fetchCards({int? limit}) => _require().fetchFeed(kind: 'card', limit: limit);

  /// What each placement shows the identified contact (null: collapse the
  /// slot). [SequenzyPlacement] calls this for you.
  static Future<Map<String, InAppMessage?>> fetchPlacements(List<String> placements) =>
      _require().fetchPlacements(placements);

  static Future<bool> report(InAppEventType type, InAppMessage message, {String? buttonId}) =>
      _require().report(type, message.id, buttonId: buttonId);

  /// How the SDK opens the app's settings when
  /// [SequenzyPushPermission.openSettings] is not set.
  static Future<void> Function() settingsOpener = _openAppSettings;

  /// Asks for notification permission (needs [SequenzyConfig.pushPermission]):
  /// the system prompt when the OS still shows one, otherwise the app's
  /// notification settings. Returns the permission afterwards.
  static Future<PushPermissionStatus?> requestPushPermission() => _require().requestPushPermission(settingsOpener);

  /// Reports the click and performs the button's action: opens its URL, or
  /// asks for push permission and reports the result with the click. Dismiss
  /// buttons report a dismissal.
  static Future<void> handleButtonPress(InAppButton button, InAppMessage message) async {
    if (!button.acts) {
      await report(InAppEventType.dismissed, message);
      return;
    }
    if (button.requestsPushPermission) {
      final client = _require();
      final pushPermission = await client.requestPushPermission(settingsOpener);
      await client.report(InAppEventType.clicked, message.id, pushPermission: pushPermission);
      return;
    }
    await report(InAppEventType.clicked, message);
    if (button.url != null) await urlOpener(button.url!);
  }

  static Future<void> _openAppSettings() => _launch('app-settings:');

  static Future<void> _launch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
