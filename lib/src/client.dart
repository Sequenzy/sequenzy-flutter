import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'geofences.dart';
import 'in_app_html.dart';
import 'live_updates.dart';
import 'models.dart';
import 'storage.dart';

const sequenzySdkVersion = '0.3.0';
const defaultApiBaseUrl = 'https://api.sequenzy.com';

enum SequenzyLogLevel { none, error, info, debug }

typedef SequenzyLogger = void Function(SequenzyLogLevel level, String message);

/// Asks the host app's backend for a fresh identity token for [email].
typedef IdentityTokenProvider = Future<String> Function(String email);

/// Asks the host app's backend for a fresh identity token for a user
/// identified with `identifyUser`: mint it for [externalId], plus [email]
/// when it is set.
typedef UserIdentityTokenProvider = Future<String> Function(String externalId, String? email);

class SequenzyConfig {
  const SequenzyConfig({
    required this.publicKey,
    required this.companyId,
    required this.appId,
    required this.platform,
    this.apiBaseUrl = defaultApiBaseUrl,
    this.identityTokenProvider,
    this.userIdentityTokenProvider,
    this.logLevel = SequenzyLogLevel.error,
    this.appVersion,
    this.osVersion,
    this.deviceName,
    this.locale,
    this.timezone,
    this.pushPermission,
    this.onLiveUpdatesRemoved,
  });

  /// Publishable key (`seq_pk_...`) restricted to your app IDs.
  final String publicKey;
  final String companyId;

  /// Bundle ID (iOS) or package name (Android), sent as `x-sequenzy-app-id`.
  final String appId;

  /// `ios`, `android` or `web`; push tokens are only registered on iOS and Android.
  final String platform;
  final String apiBaseUrl;
  final IdentityTokenProvider? identityTokenProvider;
  final UserIdentityTokenProvider? userIdentityTokenProvider;
  final SequenzyLogLevel logLevel;
  final String? appVersion;
  final String? osVersion;
  final String? deviceName;
  final String? locale;
  final String? timezone;

  /// Reads and requests notification permission. With it the SDK reports
  /// each device's permission (for your opt-in rate and the contact's
  /// `pushPermission` attribute) and shows push primers: in-app messages
  /// whose button asks for permission.
  final SequenzyPushPermission? pushPermission;

  /// Android Live Updates: called with the activity ids whose notifications
  /// to remove, after [SequenzyClient.reset] or when another person signs
  /// in. Cancel them in your notification plugin.
  final void Function(List<String> activityIds)? onLiveUpdatesRemoved;
}

class SequenzyException implements Exception {
  SequenzyException(this.message, this.code, [this.status]);

  final String message;

  /// `not_identified`, `identity_rejected` or `http`.
  final String code;
  final int? status;

  @override
  String toString() => 'SequenzyException($code): $message';
}

class _QueuedEvent {
  _QueuedEvent(this.name, this.eventId, this.properties, this.occurredAt,
      [this.type, this.transition, this.geofenceId]);

  /// `screen`, `commerce` or `geofence`; null for custom events.
  final String? type;

  /// `enter` or `exit`, for geofence events.
  final String? transition;
  final String? geofenceId;
  final String name;
  final String eventId;
  final Map<String, Object?> properties;
  final String occurredAt;

  Map<String, Object?> toJson() => {
        if (type != null) 'type': type,
        'name': name,
        'eventId': eventId,
        'properties': properties,
        'occurredAt': occurredAt,
        if (transition != null) 'transition': transition,
        if (geofenceId != null) 'geofenceId': geofenceId,
      };

  static _QueuedEvent? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final eventId = json['eventId'];
    final occurredAt = json['occurredAt'];
    if (name is! String || eventId is! String || occurredAt is! String) return null;
    final properties = json['properties'];
    return _QueuedEvent(
      name,
      eventId,
      properties is Map ? Map<String, Object?>.from(properties) : const {},
      occurredAt,
      json['type'] is String ? json['type'] as String : null,
      json['transition'] is String ? json['transition'] as String : null,
      json['geofenceId'] is String ? json['geofenceId'] as String : null,
    );
  }
}

class _Response {
  _Response(this.status, this.body);

  final int status;
  final Map<String, Object?>? body;

  bool get ok => status >= 200 && status < 300;
}

sealed class _Identified {}

class _IdentifiedResponse extends _Identified {
  _IdentifiedResponse(this.response);
  final _Response response;
}

class _NotIdentified extends _Identified {}

class _Rejected extends _Identified {}

class _Failed extends _Identified {
  _Failed(this.error);
  final Object error;
}

bool isRetryableStatus(int status) => status == 0 || status == 408 || status == 425 || status == 429 || status >= 500;

/// The SDK engine: identity, the event queue, push registration and the
/// in-app feed. Public methods run one at a time, in call order.
class SequenzyClient {
  SequenzyClient(
    this.config, {
    SequenzyStore? store,
    http.Client? httpClient,
    DateTime Function()? now,
    String Function()? uuid,
    Timer Function(Duration, void Function())? timer,
    SequenzyLogger? logger,
  })  : _store = store ?? SharedPreferencesStore(),
        _http = httpClient ?? http.Client(),
        _now = now ?? DateTime.now,
        _uuid = uuid ?? _randomUuid,
        _timer = timer ?? Timer.new,
        _logger = logger ?? ((level, message) => debugPrint('[Sequenzy] ${level.name}: $message')),
        identityTokenProvider = config.identityTokenProvider,
        userIdentityTokenProvider = config.userIdentityTokenProvider,
        logLevel = config.logLevel;

  static const maxQueuedEvents = 100;

  /// Server limit for an external ID (the contact's `externalId`).
  static const maxExternalIdLength = 255;
  static const maxBatchSize = 20;
  static const maxEventAge = Duration(hours: 24);
  static const pushRefreshInterval = Duration(hours: 24);
  static const _maxBackoff = Duration(minutes: 5);

  /// Server limit for one event's properties, serialized.
  static const maxPropertiesBytes = 8 * 1024;
  static const providerRetryInterval = Duration(minutes: 1);
  static const _requestTimeout = Duration(seconds: 20);
  static final _apnsToken = RegExp(r'^[0-9a-fA-F]{64,200}$');

  final SequenzyConfig config;
  IdentityTokenProvider? identityTokenProvider;
  UserIdentityTokenProvider? userIdentityTokenProvider;
  SequenzyLogLevel logLevel;

  final SequenzyStore _store;
  final http.Client _http;
  final DateTime Function() _now;
  final String Function() _uuid;
  final Timer Function(Duration, void Function()) _timer;
  final SequenzyLogger _logger;

  Future<void> _chain = Future.value();
  bool _loaded = false;
  List<_QueuedEvent> _events = [];
  String? _anonymousId;
  String? _email;

  /// Set by identifyUser: the app's own user ID.
  String? _externalId;
  String? _identityToken;
  String? _pushToken;
  Map<String, Object?>? _pushRegistration;
  List<LiveActivityToken> _liveActivityTokens = [];

  /// Android Live Updates this device shows or showed.
  List<LiveUpdateRecord> _liveUpdates = [];

  /// Stored ActivityKit tokens; the newest are kept.
  static const maxLiveActivityTokens = 32;

  /// Profile changes not yet accepted by the server, merged.
  Map<String, Object?>? _pendingProfile;
  Duration _backoff = Duration.zero;
  DateTime? _nextAttemptAt;
  Timer? _retryTimer;
  bool _identityBlocked = false;

  /// After a failed provider call, don't ask again before this time.
  DateTime? _providerRetryAt;

  // region Serialization and persistence

  Future<T> _run<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        await _load();
        completer.complete(await operation());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }

  Future<void> _load() async {
    if (_loaded) return;
    // _loaded is set only after every read succeeded: a failed read (storage
    // not available yet) must be retried, not replaced by empty state that
    // the next write would persist over the saved queue and identity.
    _anonymousId = await _store.getString('anonymousId');
    _email = await _store.getString('email');
    _externalId = await _store.getString('externalId');
    _identityToken = await _store.getString('identityToken');
    _pushToken = await _store.getString('pushToken');
    _pushRegistration = _decodeObject(await _store.getString('pushRegistration'));
    _pendingProfile = _decodeObject(await _store.getString('profile'));
    final liveTokens = await _store.getString('liveActivityTokens');
    if (liveTokens != null) {
      try {
        final decoded = jsonDecode(liveTokens);
        if (decoded is List) {
          _liveActivityTokens = decoded.map(LiveActivityToken.fromJson).whereType<LiveActivityToken>().toList();
        }
      } catch (_) {
        _liveActivityTokens = [];
      }
    }
    final liveUpdates = await _store.getString('liveUpdates');
    if (liveUpdates != null) {
      try {
        final decoded = jsonDecode(liveUpdates);
        if (decoded is List) {
          _liveUpdates = decoded.map(LiveUpdateRecord.fromJson).whereType<LiveUpdateRecord>().toList();
        }
      } catch (_) {
        _liveUpdates = [];
      }
    }
    final raw = await _store.getString('events');
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) _events = decoded.map(_QueuedEvent.fromJson).whereType<_QueuedEvent>().toList();
      } catch (_) {
        _events = [];
      }
    }
    _loaded = true;
  }

  Future<void> _persistEvents() =>
      _store.setString('events', jsonEncode(_events.map((event) => event.toJson()).toList()));

  Future<String> _ensureAnonymousId() async {
    if (_anonymousId == null || _anonymousId!.isEmpty) {
      _anonymousId = _uuid();
      await _store.setString('anonymousId', _anonymousId);
    }
    return _anonymousId!;
  }

  // endregion

  // region Identity

  Future<String> anonymousId() => _run(_ensureAnonymousId);

  Future<String?> email() => _run(() async => _email);

  /// The user ID passed to identifyUser, or null.
  Future<String?> externalId() => _run(() async => _externalId);

  /// One string per signed-in contact (the external ID or the email), or
  /// null while anonymous: compare it to notice that another user signed in.
  Future<String?> contactKey() => _run(() async => _identityKey);

  Future<int> queuedEventCount() => _run(() async => _events.length);

  /// One string per contact: the external ID when the app identified the
  /// user by it, otherwise the email. Null while anonymous. The space keeps
  /// an external ID from ever equalling an email.
  String? get _identityKey {
    final externalId = _externalId;
    return externalId != null ? 'external $externalId' : _email;
  }

  Map<String, Object?> get _identityFields => {
        if (_email != null) 'email': _email,
        if (_externalId != null) 'externalId': _externalId,
      };

  /// Links this installation to the contact with this email.
  Future<void> identify(String email, {String? identityToken}) => _run(() async {
        final normalized = email.trim().toLowerCase();
        if (!normalized.contains('@') || normalized.contains(RegExp(r'\s'))) {
          _log(SequenzyLogLevel.error, 'identify was called with an invalid email address');
          return;
        }
        await _identifyLocked(email: normalized, externalId: null, identityToken: identityToken);
      });

  /// Links this installation to the contact with your own user ID, for users
  /// without an email (Sign in with Apple with a hidden address, phone
  /// login). Pass [email] too when you have it. The identity token must be
  /// minted for exactly these identifiers.
  Future<void> identifyUser(String externalId, {String? email, String? identityToken}) => _run(() async {
        final id = externalId.trim();
        if (id.isEmpty || id.length > maxExternalIdLength) {
          _log(SequenzyLogLevel.error, 'identifyUser needs a user ID of 1 to $maxExternalIdLength characters');
          return;
        }
        String? normalizedEmail;
        if (email != null && email.trim().isNotEmpty) {
          normalizedEmail = email.trim().toLowerCase();
          if (!normalizedEmail.contains('@') || normalizedEmail.contains(RegExp(r'\s'))) {
            _log(SequenzyLogLevel.error, 'identifyUser was called with an invalid email address');
            return;
          }
        }
        await _identifyLocked(email: normalizedEmail, externalId: id, identityToken: identityToken);
      });

  Future<void> _identifyLocked({
    required String? email,
    required String? externalId,
    required String? identityToken,
  }) async {
    final previous = _identityKey;
    final nextKey = externalId != null ? 'external $externalId' : email;
    final identifiersChanged = _email != email || _externalId != externalId;
    final contactChanged = previous != nextKey;
    if (previous != null && contactChanged) {
      // Events and profile changes queued for the previous user must
      // not be sent as the new one.
      _events = [];
      _pendingProfile = null;
      await _persistEvents();
      await _store.setString('profile', null);
      // Another user signed in without reset: the previous user's
      // running activities stay theirs, and only the device's
      // push-to-start tokens move to the new contact. Done before the
      // device registration below, which links Android tokens again.
      // Android unlinks them on the server first, as reset does.
      if (config.platform == 'android') {
        await _reloadLiveState();
        for (final liveToken in _liveActivityTokens) {
          await _removeLiveActivityToken(liveToken.token, unlinkSubscriber: true);
        }
      }
      _liveActivityTokens = _liveActivityTokens.where((token) => token.kind == 'push_to_start').toList();
      await _persistLiveActivityTokens();
      await _clearLiveUpdates();
    }
    if (identifiersChanged) {
      // A token verifies only with the exact identifiers it was minted for.
      _email = email;
      _externalId = externalId;
      _identityToken = null;
      await _store.setString('email', email);
      await _store.setString('externalId', externalId);
      await _store.setString('identityToken', null);
    }
    if (contactChanged) {
      // Another contact's recent geofence transitions must not suppress this one's.
      await _store.setString('geofenceTransitions', null);
    }
    if (identityToken != null && identityToken.isNotEmpty) {
      _identityToken = identityToken;
      await _store.setString('identityToken', identityToken);
    }
    _identityBlocked = false;
    _providerRetryAt = null;
    await _registerPush(force: identifiersChanged);
    // Stored ActivityKit tokens link to the contact. Android sends its
    // Live Update tokens after the device registration above instead.
    if (identifiersChanged && config.platform != 'android') {
      for (final token in _liveActivityTokens) {
        await _sendLiveActivityToken(token);
      }
    }
    await _flush();
  }

  /// Forgets the user: unregisters the push token and clears identity, queue and anonymous id.
  Future<void> reset() => _run(() async {
        if (config.platform == 'android') await _reloadLiveState();
        final token = _pushToken;
        if (token != null && _pushPlatform) {
          try {
            final response = await _post('/api/v1/push/app-devices/remove', {
              'companyId': config.companyId,
              'publicKey': config.publicKey,
              'platform': config.platform,
              'token': token,
            });
            if (!response.ok) {
              _log(SequenzyLogLevel.error, 'Could not unregister the push token (HTTP ${response.status})');
            }
          } catch (error) {
            _log(SequenzyLogLevel.error, 'Could not unregister the push token: $error');
          }
        }
        final liveTokens = _liveActivityTokens;
        for (final liveToken in liveTokens) {
          await _removeLiveActivityToken(liveToken.token, unlinkSubscriber: true);
        }
        // A running activity belongs to the previous user; push-to-start
        // tokens belong to the device and are registered again below.
        _liveActivityTokens = liveTokens.where((liveToken) => liveToken.kind == 'push_to_start').toList();
        await _persistLiveActivityTokens();
        _email = null;
        _externalId = null;
        _identityToken = null;
        _pushRegistration = null;
        _anonymousId = _uuid();
        _events = [];
        _pendingProfile = null;
        await _store.setString('profile', null);
        await _store.setString('geofenceTransitions', null);
        await _store.setString('email', null);
        await _store.setString('externalId', null);
        await _store.setString('identityToken', null);
        await _store.setString('pushRegistration', null);
        await _store.setString('anonymousId', _anonymousId);
        await _persistEvents();
        _retryTimer?.cancel();
        _retryTimer = null;
        _backoff = Duration.zero;
        _nextAttemptAt = null;
        _identityBlocked = false;
        await _clearLiveUpdates();
        // Android links its Live Update tokens again with the next device
        // registration: the device was just unregistered.
        if (config.platform != 'android') {
          for (final liveToken in _liveActivityTokens) {
            await _sendLiveActivityToken(liveToken);
          }
        }
      });

  // endregion

  // region Events

  /// Queues a custom event; it is sent once the user is identified.
  Future<void> track(String name, [Map<String, Object?> properties = const {}]) => _enqueue(null, name, properties);

  /// Records that the user opened a screen, as the built-in "Screen Viewed"
  /// event that segments and sequences can use.
  Future<void> screen(String name, [Map<String, Object?> properties = const {}]) =>
      _enqueue('screen', 'screen', {...properties, 'screen': name.trim()});

  /// Browse abandonment and product interest, like the web SDK.
  Future<void> viewedProduct(CommerceProduct product) =>
      _enqueue('commerce', 'product_viewed', {'product': product.toJson()});

  Future<void> addedToCart(CommerceCartLine line) =>
      _enqueue('commerce', 'product_added_to_cart', {'product': line.toJson(), 'cartLine': line.toJson()});

  Future<void> removedFromCart(CommerceCartLine line) =>
      _enqueue('commerce', 'product_removed_from_cart', {'product': line.toJson(), 'cartLine': line.toJson()});

  /// The whole cart, for cart abandonment.
  Future<void> viewedCart(CommerceCart cart) => _enqueue('commerce', 'cart_viewed', {'cart': cart.toJson()});

  Future<void> viewedCollection(CommerceCollection collection) =>
      _enqueue('commerce', 'collection_viewed', {'collection': collection.toJson()});

  Future<void> searched(String query) => _enqueue('commerce', 'search_submitted', {'searchQuery': query.trim()});

  Future<void> _enqueue(String? type, String name, Map<String, Object?> properties) => _run(() async {
        final trimmed = name.trim();
        final screen = properties['screen'];
        if (trimmed.isEmpty || (type == 'screen' && (screen is! String || screen.isEmpty))) {
          _log(
            SequenzyLogLevel.error,
            type == 'screen' ? 'screen was called without a screen name' : 'track was called without an event name',
          );
          return;
        }
        // An event that cannot be sent must be dropped now: queued, it would
        // fail every save and every batch it is in.
        final String encoded;
        try {
          encoded = jsonEncode(properties);
        } catch (_) {
          _log(SequenzyLogLevel.error, 'Dropped "$trimmed": properties are not valid JSON (for example a DateTime)');
          return;
        }
        if (utf8.encode(encoded).length > maxPropertiesBytes) {
          _log(SequenzyLogLevel.error, 'Dropped "$trimmed": properties are larger than 8 KB');
          return;
        }
        // A copy: later changes to the caller's map must not reach the queue.
        final copy = Map<String, Object?>.from(jsonDecode(encoded) as Map);
        _events.add(_QueuedEvent(trimmed, _uuid(), copy, _now().toUtc().toIso8601String(), type));
        if (_events.length > maxQueuedEvents) {
          _events.removeRange(0, _events.length - maxQueuedEvents);
        }
        await _persistEvents();
        await _flush();
      });

  /// Sends queued events now.
  Future<void> flush() => _run(_flush);

  /// Sets the signed-in contact's name and custom attributes. Changes are
  /// kept on the device and sent once identified, like events; later calls
  /// merge into a pending update. Pass null to clear a value.
  Future<void> setProfile(ProfileUpdate update) => _run(() async {
        final Map<String, Object?> json;
        try {
          json = Map<String, Object?>.from(jsonDecode(jsonEncode(update.toJson())) as Map);
        } catch (_) {
          _log(SequenzyLogLevel.error, 'setProfile was called with values that are not JSON');
          return;
        }
        final attributes = json['attributes'];
        if (attributes is Map && utf8.encode(jsonEncode(attributes)).length > maxPropertiesBytes) {
          _log(SequenzyLogLevel.error, 'setProfile attributes are larger than 8 KB');
          return;
        }
        final previous = _pendingProfile ?? <String, Object?>{};
        final merged = <String, Object?>{...previous, ...json};
        final previousAttributes = previous['attributes'];
        if (previousAttributes is Map || attributes is Map) {
          merged['attributes'] = {
            if (previousAttributes is Map) ...previousAttributes,
            if (attributes is Map) ...attributes,
          };
        }
        _pendingProfile = merged;
        await _store.setString('profile', jsonEncode(merged));
        await _flush();
      });

  /// Subscribes an email through a published form, for people who are not
  /// signed in (newsletter or waitlist screens). Does not identify the
  /// device: call [identify] once they have an account.
  Future<SubscribeResult> subscribe(SubscribeRequest request) async {
    final email = request.email.trim();
    if (!email.contains('@') || email.contains(RegExp(r'\s'))) {
      return const SubscribeResult.failure('Enter a valid email address', retryable: false);
    }
    try {
      final response = await _post('/api/v1/app-subscribe', {
        'companyId': config.companyId,
        'publicKey': config.publicKey,
        'formId': request.formId,
        'email': email,
        if (request.firstName != null) 'firstName': request.firstName,
        if (request.lastName != null) 'lastName': request.lastName,
        if (request.phone != null) 'phone': request.phone,
        if (request.attributes != null) 'attributes': request.attributes,
      });
      if (response.ok) return const SubscribeResult.success();
      final message = response.body?['message'];
      return SubscribeResult.failure(
        message is String ? message : (_error(response).isEmpty ? 'HTTP ${response.status}' : _error(response)),
        retryable: isRetryableStatus(response.status),
      );
    } catch (error) {
      return SubscribeResult.failure('$error', retryable: true);
    }
  }

  Future<void> _flush() async {
    final profile = _pendingProfile;
    if (profile != null) {
      if (_identityKey == null || _identityBlocked) return;
      final next = _nextAttemptAt;
      if (next != null && next.isAfter(_now())) return;
      final outcome = await _sendProfile(profile);
      if (outcome == 'retry') {
        _scheduleRetry();
        return;
      }
      if (outcome == 'stop') return;
      _backoff = Duration.zero;
      _nextAttemptAt = null;
      _pendingProfile = null;
      await _store.setString('profile', null);
    }
    await _dropStaleEvents();
    while (_events.isNotEmpty) {
      if (_identityKey == null || _identityBlocked) return;
      final next = _nextAttemptAt;
      if (next != null && next.isAfter(_now())) return;
      final batch = _events.take(maxBatchSize).toList();
      final outcome = await _sendBatch(batch);
      switch (outcome) {
        case 'delivered':
          _backoff = Duration.zero;
          _nextAttemptAt = null;
          await _remove(batch);
        case 'dropped':
          await _remove(batch);
        case 'retry':
          _scheduleRetry();
          return;
        default:
          return;
      }
    }
  }

  Future<String> _sendBatch(List<_QueuedEvent> batch) async {
    final result = await _withIdentity((identity, token) => _post('/api/v1/app-events', {
          'companyId': config.companyId,
          'publicKey': config.publicKey,
          ...identity,
          'identityToken': token,
          'events': batch.map((event) => event.toJson()).toList(),
        }));
    switch (result) {
      case _NotIdentified() || _Rejected():
        return 'stop';
      case _Failed(:final error):
        _log(SequenzyLogLevel.info, 'Event delivery failed, will retry: $error');
        return 'retry';
      case _IdentifiedResponse(:final response):
        if (response.ok) {
          final rejected = response.body?['rejected'];
          if (rejected is List) {
            for (final entry in rejected) {
              _log(SequenzyLogLevel.error, 'Event rejected: ${entry is Map ? entry['error'] : entry}');
            }
          }
          return 'delivered';
        }
        if (isRetryableStatus(response.status)) return 'retry';
        _log(SequenzyLogLevel.error, 'Dropping ${batch.length} events: HTTP ${response.status} ${_error(response)}');
        return 'dropped';
    }
  }

  Future<String> _sendProfile(Map<String, Object?> profile) async {
    final result = await _withIdentity((identity, token) => _post('/api/v1/app-attributes', {
          'companyId': config.companyId,
          'publicKey': config.publicKey,
          ...identity,
          'identityToken': token,
          ...profile,
        }));
    switch (result) {
      case _NotIdentified() || _Rejected():
        return 'stop';
      case _Failed():
        return 'retry';
      case _IdentifiedResponse(:final response):
        if (response.ok) return 'delivered';
        if (isRetryableStatus(response.status)) return 'retry';
        _log(SequenzyLogLevel.error, 'Profile update rejected: HTTP ${response.status} ${_error(response)}');
        return 'dropped';
    }
  }

  Future<void> _remove(List<_QueuedEvent> batch) async {
    final ids = batch.map((event) => event.eventId).toSet();
    _events.removeWhere((event) => ids.contains(event.eventId));
    await _persistEvents();
  }

  Future<void> _dropStaleEvents() async {
    final cutoff = _now().subtract(maxEventAge);
    final before = _events.length;
    _events.removeWhere((event) {
      final time = DateTime.tryParse(event.occurredAt);
      return time == null || time.isBefore(cutoff);
    });
    if (_events.length != before) {
      _log(SequenzyLogLevel.info, 'Dropped ${before - _events.length} events older than 24 hours');
      await _persistEvents();
    }
  }

  void _scheduleRetry() {
    final doubled = _backoff == Duration.zero ? const Duration(seconds: 1) : _backoff * 2;
    _backoff = doubled > _maxBackoff ? _maxBackoff : doubled;
    _nextAttemptAt = _now().add(_backoff);
    _retryTimer?.cancel();
    _retryTimer = _timer(_backoff, () {
      _retryTimer = null;
      unawaited(_run(() async {
        _nextAttemptAt = null;
        await _flush();
      }));
    });
  }

  // endregion

  // region Push

  bool get _pushPlatform => config.platform == 'ios' || config.platform == 'android';

  Future<String?> pushToken() => _run(() async => _pushToken);

  /// Registers the device's APNs or FCM token (`getToken()` on Android,
  /// `getAPNSToken()` on iOS with Firebase Messaging).
  Future<void> setPushToken(String token) => _run(() async {
        final trimmed = token.trim();
        if (trimmed.isEmpty) return;
        if (!_pushPlatform) {
          _log(SequenzyLogLevel.error, 'Push tokens are only registered on iOS and Android');
          return;
        }
        if (config.platform == 'ios' && !_apnsToken.hasMatch(trimmed)) {
          // Sequenzy sends to iOS through APNs, so it needs the device token,
          // not the FCM registration token getToken() returns.
          _log(SequenzyLogLevel.error,
              'On iOS pass the APNs device token: FirebaseMessaging.instance.getAPNSToken(), not getToken()');
          return;
        }
        final changed = _pushToken != trimmed;
        _pushToken = trimmed;
        await _store.setString('pushToken', trimmed);
        await _registerPush(force: changed);
      });

  /// Registers the token when it or the user changed, or the last registration is a day old.
  Future<void> registerPushIfNeeded({bool force = false}) => _run(() => _registerPush(force: force));

  /// The permission from [SequenzyConfig.pushPermission]; null when unknown.
  Future<PushPermissionStatus?> _readPushPermission() async {
    final handler = config.pushPermission;
    if (handler == null) return null;
    try {
      return await handler.getStatus();
    } catch (error) {
      _log(SequenzyLogLevel.info, 'Could not read push permission: $error');
      return null;
    }
  }

  Future<void> _registerPush({required bool force}) async {
    final token = _pushToken;
    if (token == null || !_pushPlatform) return;
    final identity = _identityKey ?? '';
    final permission = await _readPushPermission();
    final last = _pushRegistration;
    final lastAt = last?['registeredAt'];
    if (!force &&
        last != null &&
        last['token'] == token &&
        last['email'] == identity &&
        (permission == null || last['permission'] == permission.wire) &&
        lastAt is int &&
        _now().millisecondsSinceEpoch - lastAt < pushRefreshInterval.inMilliseconds) {
      return;
    }

    final base = <String, Object?>{
      'companyId': config.companyId,
      'publicKey': config.publicKey,
      'platform': config.platform,
      'token': token,
      'anonymousId': await _ensureAnonymousId(),
      if (permission != null) 'permission': permission.wire,
      if (config.appVersion?.isNotEmpty == true) 'appVersion': config.appVersion,
      if (config.osVersion?.isNotEmpty == true) 'osVersion': config.osVersion,
      if (config.deviceName?.isNotEmpty == true) 'deviceName': config.deviceName,
      if (config.locale?.isNotEmpty == true) 'locale': config.locale,
      if (config.timezone?.isNotEmpty == true) 'timezone': config.timezone,
    };

    _Response? response;
    if (_identityKey != null) {
      final result = await _withIdentity((fields, identityToken) =>
          _post('/api/v1/push/app-devices', {...base, ...fields, 'identityToken': identityToken}));
      switch (result) {
        case _IdentifiedResponse(response: final identified):
          response = identified;
        case _Failed(:final error):
          _log(SequenzyLogLevel.info, 'Push registration failed: $error');
          return;
        case _NotIdentified() || _Rejected():
          // Keep the device reachable; it links on the next identify with a valid token.
          response = await _tryPost('/api/v1/push/app-devices', base);
      }
    } else {
      response = await _tryPost('/api/v1/push/app-devices', base);
    }
    if (response == null) return;
    if (!response.ok) {
      _log(SequenzyLogLevel.error, 'Push registration failed: HTTP ${response.status} ${_error(response)}');
      return;
    }
    final identified = response.body?['identified'] == true;
    _pushRegistration = {
      'token': token,
      'email': identified ? identity : '',
      'registeredAt': _now().millisecondsSinceEpoch,
      if (permission != null) 'permission': permission.wire,
    };
    await _store.setString('pushRegistration', jsonEncode(_pushRegistration));
    if (response.body?['pushConfigured'] == false) {
      _log(SequenzyLogLevel.info,
          'Device registered, but ${config.platform} push credentials are not set up in Sequenzy yet');
    }
    // Android Live Update tokens are sent to this FCM token and contact:
    // link them again whenever either may have changed.
    if (config.platform == 'android') {
      for (final liveToken in _liveActivityTokens) {
        await _sendLiveActivityToken(liveToken);
      }
    }
  }

  /// Asks for notification permission the way a push primer does: the
  /// system prompt when the OS still shows one, otherwise (the contact
  /// turned notifications off) the app's notification settings through
  /// [openSettings]. Runs outside the serialized queue, since the prompt waits
  /// for the user. Returns null without [SequenzyConfig.pushPermission].
  Future<PushPermissionStatus?> requestPushPermission(Future<void> Function() openSettings) async {
    final handler = config.pushPermission;
    if (handler == null) {
      _log(SequenzyLogLevel.error, 'Pass pushPermission to SequenzyConfig to ask for notification permission');
      return null;
    }
    try {
      final before = await handler.getStatus();
      if (before == PushPermissionStatus.granted || before == PushPermissionStatus.ephemeral) return before;
      final after = await handler.request();
      // iOS answers a second request without a prompt, and Android stops
      // prompting after repeated denials: send them to Settings instead.
      if (before == PushPermissionStatus.denied && after == PushPermissionStatus.denied) {
        // The app-settings: fallback URL only exists on iOS.
        final opener = handler.openSettings ?? (config.platform == 'ios' ? openSettings : null);
        if (opener != null) {
          await opener();
        } else {
          _log(SequenzyLogLevel.error,
              'Notifications are turned off; pass SequenzyPushPermission.openSettings (for example openAppSettings from permission_handler) so the SDK can open the settings on Android');
        }
      }
      await registerPushIfNeeded();
      return after;
    } catch (error) {
      _log(SequenzyLogLevel.error, 'Push permission request failed: $error');
      return null;
    }
  }

  /// Registers an ActivityKit push token your native Live Activity code
  /// received (iOS only): `Activity<T>.pushToStartTokenUpdates` as
  /// [LiveActivityToken.pushToStart], or a running activity's
  /// `pushTokenUpdates` as [LiveActivityToken.update] with its
  /// `sequenzy.activityId`. A newer token for the same type or activity
  /// replaces the stored one.
  Future<void> registerLiveActivityToken(LiveActivityToken token) => _run(() async {
        if (!_pushPlatform) {
          _log(SequenzyLogLevel.error, 'Live Activities are only available in apps');
          return;
        }
        if (!token.isValid) {
          _log(SequenzyLogLevel.error,
              "Ignoring a Live Activity token: it needs a hex token, the Swift type name and, for update tokens, the activity's sequenzy.activityId");
          return;
        }
        final kept = [..._liveActivityTokens.where((stored) => !token.replaces(stored)), token];
        _liveActivityTokens =
            kept.length > maxLiveActivityTokens ? kept.sublist(kept.length - maxLiveActivityTokens) : kept;
        await _persistLiveActivityTokens();
        await _sendLiveActivityToken(token);
      });

  /// Reports that an activity ended or was dismissed, so Sequenzy stops sending to it.
  Future<void> liveActivityEnded(String rawToken) => _run(() async {
        final token = rawToken.trim().toLowerCase();
        if (!_liveActivityTokens.any((stored) => stored.token == token)) return;
        _liveActivityTokens = _liveActivityTokens.where((stored) => stored.token != token).toList();
        await _persistLiveActivityTokens();
        await _removeLiveActivityToken(token, unlinkSubscriber: false);
      });

  Future<List<LiveActivityToken>> liveActivityTokens() => _run(() async => List.of(_liveActivityTokens));

  Future<void> _persistLiveActivityTokens() => _store.setString(
      'liveActivityTokens',
      _liveActivityTokens.isEmpty ? null : jsonEncode(_liveActivityTokens.map((token) => token.toJson()).toList()));

  Future<void> _sendLiveActivityToken(LiveActivityToken token) async {
    const path = '/api/v1/push/live-activities';
    final android = config.platform == 'android';
    // Sequenzy sends Android Live Updates to the FCM token; without one
    // there is nothing to link, and the device registration sends it later.
    if (android && _pushToken == null) return;
    final base = <String, Object?>{
      'companyId': config.companyId,
      'publicKey': config.publicKey,
      if (android) 'platform': 'android',
      ...token.toJson(),
      'anonymousId': await _ensureAnonymousId(),
      // Links the token to this installation's push device, when there is one.
      if (_pushToken != null) 'deviceToken': _pushToken,
      if (config.appVersion?.isNotEmpty == true) 'appVersion': config.appVersion,
      if (config.osVersion?.isNotEmpty == true) 'osVersion': config.osVersion,
    };
    _Response? response;
    if (_identityKey != null) {
      final result = await _withIdentity(
          (identity, identityToken) => _post(path, {...base, ...identity, 'identityToken': identityToken}));
      switch (result) {
        case _IdentifiedResponse(response: final identified):
          response = identified;
        case _Failed(:final error):
          _log(SequenzyLogLevel.info, 'Live Activity token registration failed: $error');
          return;
        case _NotIdentified() || _Rejected():
          // Store it anonymously; Sequenzy can address it once the next
          // identify links it to the contact.
          response = await _tryPost(path, base);
      }
    } else {
      response = await _tryPost(path, base);
    }
    if (response != null && !response.ok) {
      _log(SequenzyLogLevel.error,
          'Live Activity token registration failed: HTTP ${response.status} ${_error(response)}');
    }
  }

  // region Android Live Updates (rules in live_updates.dart)

  /// Android: reports that this device draws Live Updates of [activityType]
  /// (use your iOS ActivityAttributes type name, so one backend call reaches
  /// both), with a push-to-start token generated once per type.
  Future<void> observeLiveUpdates(String activityType) => _runLive(() async {
        if (!_requireAndroid('observeLiveUpdates')) return;
        LiveActivityToken? existing;
        for (final token in _liveActivityTokens) {
          if (token.kind == 'push_to_start' && token.activityType == activityType) existing = token;
        }
        final token = existing ?? LiveActivityToken.pushToStart(activityType: activityType, token: _newLiveUpdateToken());
        if (!token.isValid) {
          _log(SequenzyLogLevel.error, 'observeLiveUpdates: "$activityType" is not a valid type name');
          return;
        }
        // A known token is linked again with every device registration.
        if (existing != null) return;
        _liveActivityTokens = _capTokens([..._liveActivityTokens, token]);
        await _persistLiveActivityTokens();
        await _sendLiveActivityToken(token);
      });

  /// Android: applies a Sequenzy Live Update push (`RemoteMessage.data`) and
  /// says what to show. Returns null for other messages. Pass [canShow]
  /// false when the app does not draw this type or may not post
  /// notifications: Sequenzy then stops counting the activity as running.
  Future<LiveUpdateDecision?> handleLiveUpdate(Map<dynamic, dynamic> data, {bool canShow = true}) => _runLive(() async {
        final payload = LiveUpdatePayload.fromData(data);
        if (payload == null) return null;
        return _applyLiveUpdateStep(
            receiveLiveUpdate(_liveUpdates, payload, canShow: canShow, now: _now(), newToken: _newLiveUpdateToken));
      });

  /// Android: starts an activity from the app, so your backend can update and end it by [activityId].
  Future<LiveUpdateDecision> startLiveUpdate({
    required String activityType,
    required String activityId,
    Map<String, Object?> attributes = const {},
    Map<String, Object?> contentState = const {},
  }) =>
      _runLive(() async {
        if (!_requireAndroid('startLiveUpdate')) return const LiveUpdateDecision.ignore('invalid');
        return _applyLiveUpdateStep(startLiveUpdateLocally(_liveUpdates,
            activityType: activityType,
            activityId: activityId,
            attributes: attributes,
            contentState: contentState,
            now: _now(),
            newToken: _newLiveUpdateToken));
      });

  /// Android: updates a running activity from the app.
  Future<LiveUpdateDecision> updateLiveUpdate(String activityId, Map<String, Object?> contentState) =>
      _runLive(() async => _applyLiveUpdateStep(updateLiveUpdateLocally(_liveUpdates, activityId, contentState, _now())));

  /// Android: ends a running activity from the app and tells Sequenzy, so
  /// later backend updates are not sent. Without [dismissAt] the final
  /// content stays up to four hours, as on iOS.
  Future<LiveUpdateDecision> endLiveUpdate(String activityId, {Map<String, Object?>? contentState, DateTime? dismissAt}) =>
      _runLive(() async => _applyLiveUpdateStep(
          endLiveUpdateLocally(_liveUpdates, activityId, _now(), contentState: contentState, dismissAt: dismissAt)));

  /// Android: call when the person swipes a Live Update away.
  Future<void> liveUpdateDismissed(String activityId) =>
      _runLive(() async => _applyLiveUpdateStep(dismissLiveUpdate(_liveUpdates, activityId)));

  /// Android: the Live Updates this device shows now.
  Future<List<LiveUpdateActivity>> liveUpdates() => _runLive(
      () async => _liveUpdates.where((record) => record.state == 'active').map((record) => record.toActivity()).toList());

  bool _requireAndroid(String method) {
    if (config.platform == 'android') return true;
    _log(SequenzyLogLevel.error, '$method is for Android Live Updates; on iOS use Live Activities');
    return false;
  }

  /// 64 random hex characters.
  String _newLiveUpdateToken() => '${_uuid()}${_uuid()}'.replaceAll('-', '').toLowerCase();

  /// Runs a Live Update operation on the stored state: on Android,
  /// firebase_messaging's background handler runs in another isolate with
  /// its own client, and both write the same keys.
  Future<T> _runLive<T>(Future<T> Function() operation) => _run(() async {
        await _reloadLiveState();
        return operation();
      });

  Future<void> _reloadLiveState() async {
    final store = _store;
    if (store is! ReloadableSequenzyStore) return;
    try {
      await store.reload();
    } catch (error) {
      _log(SequenzyLogLevel.info, 'Could not reload stored Live Update state: $error');
      return;
    }
    _liveActivityTokens = _decodeList(await store.getString('liveActivityTokens'), LiveActivityToken.fromJson);
    _liveUpdates = _decodeList(await store.getString('liveUpdates'), LiveUpdateRecord.fromJson);
  }

  static List<T> _decodeList<T>(String? raw, T? Function(Object?) parse) {
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.map(parse).whereType<T>().toList() : [];
    } catch (_) {
      return [];
    }
  }

  /// Oldest update tokens go first; push-to-start tokens are kept.
  List<LiveActivityToken> _capTokens(List<LiveActivityToken> tokens) {
    if (tokens.length <= maxLiveActivityTokens) return tokens;
    final starts = tokens.where((token) => token.kind == 'push_to_start').toList();
    final updates = tokens.where((token) => token.kind != 'push_to_start').toList();
    final room = (maxLiveActivityTokens - starts.length).clamp(0, updates.length);
    return [
      ...(starts.length > maxLiveActivityTokens ? starts.sublist(starts.length - maxLiveActivityTokens) : starts),
      ...updates.sublist(updates.length - room),
    ];
  }

  Future<LiveUpdateDecision> _applyLiveUpdateStep(LiveUpdateStep step) async {
    _liveUpdates = step.records;
    await _store.setString('liveUpdates', jsonEncode(step.records.map((record) => record.toJson()).toList()));
    final drop = {if (step.forget != null) step.forget!, if (step.remove != null) step.remove!};
    if (drop.isNotEmpty) {
      _liveActivityTokens = _liveActivityTokens.where((stored) => !drop.contains(stored.token)).toList();
      await _persistLiveActivityTokens();
    }
    if (step.remove != null) await _removeLiveActivityToken(step.remove!, unlinkSubscriber: false);
    final register = step.register;
    if (register != null) {
      final token = LiveActivityToken.update(
          activityType: register.activityType, activityId: register.activityId, token: register.token);
      if (token.isValid) {
        _liveActivityTokens = _capTokens([..._liveActivityTokens.where((stored) => !token.replaces(stored)), token]);
        await _persistLiveActivityTokens();
        await _sendLiveActivityToken(token);
      }
    }
    return step.decision;
  }

  /// Forgets every Live Update and asks the app to remove those still showing, running or ended.
  Future<void> _clearLiveUpdates() async {
    final running = _liveUpdates
        .where((record) => record.state != 'dismissed' && record.token.isNotEmpty)
        .map((record) => record.activityId)
        .toList();
    _liveUpdates = [];
    await _store.setString('liveUpdates', null);
    if (running.isEmpty) return;
    try {
      config.onLiveUpdatesRemoved?.call(running);
    } catch (error) {
      _log(SequenzyLogLevel.error, 'onLiveUpdatesRemoved threw: $error');
    }
  }

  // endregion

  Future<void> _removeLiveActivityToken(String token, {required bool unlinkSubscriber}) async {
    final response = await _tryPost('/api/v1/push/live-activities/remove', {
      'companyId': config.companyId,
      'publicKey': config.publicKey,
      'token': token,
      if (unlinkSubscriber) 'unlinkSubscriber': true,
    });
    if (response != null && !response.ok) {
      _log(SequenzyLogLevel.error, 'Could not report the Live Activity ended (HTTP ${response.status})');
    }
  }

  /// Reports a push as `delivered` or `clicked`; the payload's click token authenticates it.
  Future<void> reportPush(String type, PushPayload payload) async {
    try {
      final response = await _http.post(
        Uri.parse(payload.eventsUrl),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'pushSendId': payload.pushSendId,
          'deviceId': payload.deviceId,
          'token': payload.clickToken,
          'type': type,
        }),
      ).timeout(_requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _log(SequenzyLogLevel.error, 'Push $type report failed: HTTP ${response.statusCode}');
      }
    } catch (error) {
      _log(SequenzyLogLevel.error, 'Push $type report failed: $error');
    }
  }

  // endregion

  // region In-app

  /// Open messages (`kind: 'message'`) or cards (`kind: 'card'`), in server order.
  /// [formats] lists the message formats the caller renders; null means the
  /// native formats, so `html` messages arrive only when listed.
  Future<List<InAppMessage>> fetchFeed({String? kind, int? limit, List<String>? formats}) => _run(() async {
        final result = await _withIdentity((identity, token) => _post('/api/v1/in-app/feed', {
              'companyId': config.companyId,
              'publicKey': config.publicKey,
              ...identity,
              'identityToken': token,
              if (kind != null) 'kind': kind,
              if (limit != null) 'limit': limit,
              if (formats != null) 'formats': formats,
              // Push primers come only when this app can ask for permission
              if (config.pushPermission != null) 'actions': [InAppButton.requestPushPermissionAction],
            }));
        switch (result) {
          case _NotIdentified():
            throw SequenzyException('Call identify or identifyUser with an identity token first', 'not_identified');
          case _Rejected():
            throw SequenzyException('The identity token was rejected', 'identity_rejected');
          case _Failed(:final error):
            throw error;
          case _IdentifiedResponse(:final response):
            if (!response.ok) {
              throw SequenzyException('HTTP ${response.status} ${_error(response)}'.trim(), 'http', response.status);
            }
            final messages = response.body?['messages'];
            return messages is List
                ? messages.map(InAppMessage.fromJson).whereType<InAppMessage>().toList()
                : <InAppMessage>[];
        }
      });

  /// Placement keys one request can ask for.
  static const maxPlacementsPerRequest = 10;

  /// What each placement shows the identified contact: the highest-priority
  /// open item per key, or null when the slot should collapse. Up to 10 keys.
  Future<Map<String, InAppMessage?>> fetchPlacements(List<String> placements) => _run(() async {
        final keys = <String>[
          for (final key in {...placements.map((key) => key.trim())})
            if (key.isNotEmpty) key,
        ].take(maxPlacementsPerRequest).toList();
        if (keys.isEmpty) return <String, InAppMessage?>{};
        final result = await _withIdentity((identity, token) => _post('/api/v1/in-app/feed/placements', {
              'companyId': config.companyId,
              'publicKey': config.publicKey,
              ...identity,
              'identityToken': token,
              'placements': keys,
              if (config.pushPermission != null) 'actions': [InAppButton.requestPushPermissionAction],
            }));
        switch (result) {
          case _NotIdentified():
            throw SequenzyException('Call identify or identifyUser with an identity token first', 'not_identified');
          case _Rejected():
            throw SequenzyException('The identity token was rejected', 'identity_rejected');
          case _Failed(:final error):
            throw error;
          case _IdentifiedResponse(:final response):
            if (!response.ok) {
              throw SequenzyException('HTTP ${response.status} ${_error(response)}'.trim(), 'http', response.status);
            }
            final items = <String, InAppMessage?>{for (final key in keys) key: null};
            final entries = response.body?['placements'];
            if (entries is List) {
              for (final entry in entries) {
                if (entry is! Map) continue;
                final placement = entry['placement'];
                if (placement is! String || !items.containsKey(placement)) continue;
                items[placement] = InAppMessage.fromJson(entry['message']);
              }
            }
            return items;
        }
      });

  // region Geofences

  /// The nearest active geofences around a position, rounded to two decimals
  /// here whatever the caller passes.
  Future<NearbyGeofences> fetchNearbyGeofences(double latitude, double longitude, int limit) => _run(() async {
        final result = await _withIdentity((identity, token) => _post('/api/v1/geofences/nearby', {
              'companyId': config.companyId,
              'publicKey': config.publicKey,
              ...identity,
              'identityToken': token,
              'latitude': Geofencing.roundCoordinate(latitude),
              'longitude': Geofencing.roundCoordinate(longitude),
              'limit': limit.clamp(1, 99),
            }));
        switch (result) {
          case _NotIdentified():
            throw SequenzyException('Call identify or identifyUser with an identity token first', 'not_identified');
          case _Rejected():
            throw SequenzyException('The identity token was rejected', 'identity_rejected');
          case _Failed(:final error):
            throw error;
          case _IdentifiedResponse(:final response):
            if (!response.ok) {
              throw SequenzyException('HTTP ${response.status} ${_error(response)}'.trim(), 'http', response.status);
            }
            return NearbyGeofences.fromJson(response.body);
        }
      });

  /// The signed-in user's identifiers and identity token, for native code
  /// that reports while Dart is not running (the geofence plugins). Asks the
  /// identity token provider when no token is stored or [refresh] is set.
  /// `email` is null for a user identified by external ID only.
  Future<({String? email, String? externalId, String identityToken})?> identityCredentials({bool refresh = false}) =>
      _run(() async {
        if (_identityKey == null) return null;
        var token = _identityToken;
        if (token == null || refresh) {
          token = await _tokenFromProvider() ?? (refresh ? token : null);
        }
        if (token == null) return null;
        return (email: _email, externalId: _externalId, identityToken: token);
      });

  /// Queues an enter or exit the OS reported. The refresh region and a repeat
  /// of the same transition within a minute are ignored. Returns whether it
  /// was queued.
  Future<bool> trackGeofenceTransition(String geofenceId, GeofenceTransition transition, {DateTime? at}) =>
      _run(() async {
        final id = geofenceId.trim();
        if (id.isEmpty || id == GeofenceRegion.refreshRegionId) return false;
        // Visits belong to a contact; never queue one for whoever signs in next.
        if (_identityKey == null) return false;
        final occurredAt = (at ?? _now()).toUtc();
        final recent = <String, int>{};
        final stored = _decodeObject(await _store.getString('geofenceTransitions'));
        stored?.forEach((key, value) {
          if (value is num) recent[key] = value.toInt();
        });
        final key = '$id:${transition.wire}';
        final last = recent[key];
        final millis = occurredAt.millisecondsSinceEpoch;
        if (last != null && (millis - last).abs() < Geofencing.debounce.inMilliseconds) {
          _log(SequenzyLogLevel.debug, 'Ignored repeated geofence ${transition.wire} for $id');
          return false;
        }
        recent[key] = millis;
        final cutoff = _now().millisecondsSinceEpoch - maxEventAge.inMilliseconds;
        recent.removeWhere((_, value) => value <= cutoff);
        await _store.setString('geofenceTransitions', jsonEncode(recent));
        _events.add(_QueuedEvent('geofence', _uuid(), const {}, occurredAt.toIso8601String(), 'geofence',
            transition.wire, id));
        if (_events.length > maxQueuedEvents) {
          _events.removeRange(0, _events.length - maxQueuedEvents);
        }
        await _persistEvents();
        await _flush();
        return true;
      });

  // endregion

  /// Reports `displayed`, `clicked`, `dismissed` or `read` for a feed item.
  /// [buttonId] names the control clicked in a custom HTML message. A push
  /// primer's click carries the permission read after asking.
  Future<bool> report(
    InAppEventType type,
    String messageId, {
    String? buttonId,
    PushPermissionStatus? pushPermission,
  }) =>
      _run(() async {
        final result = await _withIdentity((identity, token) => _post('/api/v1/in-app/feed/events', {
              'companyId': config.companyId,
              'publicKey': config.publicKey,
              ...identity,
              'identityToken': token,
              'messageId': messageId,
              'type': type.name,
              if (buttonId != null && type == InAppEventType.clicked && InAppHtmlBridgeMessage.isValidButtonId(buttonId))
                'buttonId': buttonId,
              if (pushPermission != null) 'pushPermission': pushPermission.wire,
            }));
        final ok = result is _IdentifiedResponse && result.response.ok;
        if (!ok) _log(SequenzyLogLevel.error, 'Could not report in-app ${type.name} for $messageId');
        return ok;
      });

  // endregion

  // region Identity tokens and HTTP

  Future<_Identified> _withIdentity(
      Future<_Response> Function(Map<String, Object?> identity, String token) operation) async {
    if (_identityKey == null || _identityBlocked) return _NotIdentified();
    final identity = _identityFields;
    var usedProvider = false;
    var token = _identityToken;
    if (token == null) {
      token = await _tokenFromProvider();
      usedProvider = true;
    }
    if (token == null) {
      _log(SequenzyLogLevel.info,
          'No identity token yet; pass one to identify or identifyUser, or set an identity token provider');
      return _NotIdentified();
    }
    while (true) {
      final _Response response;
      try {
        response = await operation(identity, token!);
      } catch (error) {
        return _Failed(error);
      }
      final rejected = (response.status == 401 || response.status == 403) &&
          response.body?['code'] == 'invalid_web_tracking_identity';
      if (!rejected) return _IdentifiedResponse(response);
      _identityToken = null;
      await _store.setString('identityToken', null);
      if (!usedProvider) {
        usedProvider = true;
        final fresh = await _tokenFromProvider();
        if (fresh != null) {
          token = fresh;
          continue;
        }
      }
      _identityBlocked = true;
      _log(SequenzyLogLevel.error, 'The identity token was rejected; call identify or identifyUser with a fresh token');
      return _Rejected();
    }
  }

  /// A fresh token for the current identity: from [userIdentityTokenProvider]
  /// for a user identified by external ID, otherwise from
  /// [identityTokenProvider] with the email.
  Future<String?> _tokenFromProvider() async {
    final key = _identityKey;
    final email = _email;
    final externalId = _externalId;
    Future<String> Function()? request;
    if (externalId != null) {
      final provider = userIdentityTokenProvider;
      if (provider != null) request = () => provider(externalId, email);
    } else if (email != null) {
      final provider = identityTokenProvider;
      if (provider != null) request = () => provider(email);
    }
    if (request == null) return null;
    final retryAt = _providerRetryAt;
    if (retryAt != null && _now().isBefore(retryAt)) return null;
    try {
      // Calls are serialized, so a provider that never completes (or awaits a
      // Sequenzy call) would stall every later call without the timeout.
      final token = await request().timeout(_requestTimeout);
      if (token.isEmpty || _identityKey != key) return null;
      _identityToken = token;
      await _store.setString('identityToken', token);
      return token;
    } catch (error) {
      _providerRetryAt = _now().add(providerRetryInterval);
      _log(SequenzyLogLevel.error, 'The identity token provider failed: $error; retrying in a minute');
      return null;
    }
  }

  Future<_Response> _post(String path, Map<String, Object?> body) async {
    final base = config.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final response = await _http
        .post(
          Uri.parse('$base$path'),
          headers: {
            'content-type': 'application/json',
            'x-sequenzy-key': config.publicKey,
            'x-sequenzy-app-id': config.appId,
            'user-agent': 'sequenzy-flutter/$sequenzySdkVersion',
          },
          body: jsonEncode(body),
        )
        .timeout(_requestTimeout);
    return _Response(response.statusCode, _decodeObject(response.body));
  }

  Future<_Response?> _tryPost(String path, Map<String, Object?> body) async {
    try {
      return await _post(path, body);
    } catch (error) {
      _log(SequenzyLogLevel.info, 'Request to $path failed: $error');
      return null;
    }
  }

  String _error(_Response response) {
    final error = response.body?['error'];
    return error is String ? error : '';
  }

  void _log(SequenzyLogLevel level, String message) {
    if (level == SequenzyLogLevel.none || level.index > logLevel.index) return;
    _logger(level, message);
  }

  // endregion
}

Map<String, Object?>? _decodeObject(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, Object?>.from(decoded) : null;
  } catch (_) {
    return null;
  }
}

String _randomUuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
