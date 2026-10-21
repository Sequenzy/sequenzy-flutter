import 'dart:async';

import 'package:url_launcher/url_launcher.dart';

import 'client.dart';
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

  static Future<List<InAppMessage>> fetchMessages() => _require().fetchFeed(kind: 'message');

  static Future<List<InAppMessage>> fetchCards({int? limit}) => _require().fetchFeed(kind: 'card', limit: limit);

  static Future<bool> report(InAppEventType type, InAppMessage message) => _require().report(type, message.id);

  /// Reports the click and opens the button's URL; dismiss buttons report a dismissal.
  static Future<void> handleButtonPress(InAppButton button, InAppMessage message) async {
    if (!button.opensUrl) {
      await report(InAppEventType.dismissed, message);
      return;
    }
    await report(InAppEventType.clicked, message);
    if (button.url != null) await urlOpener(button.url!);
  }

  static Future<void> _launch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
