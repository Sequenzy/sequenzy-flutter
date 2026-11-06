import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sequenzy_flutter/sequenzy_flutter.dart';

final fixtures = Directory('../contract/fixtures');
String fixture(String name) => File('${fixtures.path}/$name').readAsStringSync();
final contract = jsonDecode(fixture('requests.json')) as Map<String, dynamic>;
Map<String, dynamic> spec(String name) =>
    (contract['requests'] as List).cast<Map<String, dynamic>>().firstWhere((entry) => entry['name'] == name);
final pushToken = (spec('registerAnonymousDevice')['body'] as Map)['token'] as String;
const email = 'jane@example.com';
const identityToken = 'seq_wid_contract.token';

class Recorded {
  Recorded(this.url, this.headers, this.body);
  final String url;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
}

typedef Responder = Future<http.Response?> Function(Recorded request);

class Harness {
  final requests = <Recorded>[];
  final responders = <Responder>[];
  final store = MemoryStore();
  final timers = <void Function()>[];
  var now = DateTime.fromMillisecondsSinceEpoch(1792000000000, isUtc: true);
  var uuid = 0;

  late final http.Client httpClient = MockClient((request) async {
    final recorded =
        Recorded(request.url.toString(), request.headers, jsonDecode(request.body) as Map<String, dynamic>);
    requests.add(recorded);
    for (final responder in responders) {
      final response = await responder(recorded);
      if (response != null) return response;
    }
    if (recorded.url.endsWith('/api/v1/app-events')) {
      return http.Response('{"success":true,"accepted":1,"rejected":[]}', 202);
    }
    if (recorded.url.endsWith('/api/v1/push/app-devices')) {
      return http.Response('{"success":true,"deviceId":"dev_1","identified":true,"pushConfigured":true}', 201);
    }
    return http.Response('{"success":true}', 200);
  });

  SequenzyClient make({IdentityTokenProvider? provider, String platform = 'ios', SequenzyPushPermission? pushPermission}) {
    final config = contract['config'] as Map<String, dynamic>;
    return SequenzyClient(
      SequenzyConfig(
        publicKey: config['publicKey'] as String,
        companyId: config['companyId'] as String,
        appId: config['appId'] as String,
        apiBaseUrl: config['apiBaseUrl'] as String,
        platform: platform,
        identityTokenProvider: provider,
        logLevel: SequenzyLogLevel.none,
        appVersion: '1.0',
        osVersion: '18.0',
        deviceName: 'Test',
        locale: 'en-US',
        timezone: 'UTC',
        pushPermission: pushPermission,
      ),
      store: store,
      httpClient: httpClient,
      now: () => now,
      uuid: () => 'uuid-${++uuid}',
      timer: (duration, callback) {
        timers.add(callback);
        return Timer(const Duration(days: 1), () {});
      },
    );
  }

  List<Recorded> to(String path) => requests.where((request) => request.url.endsWith(path)).toList();

  void respondTo(String path, int status, Object body, {int times = 1 << 30}) {
    var remaining = times;
    responders.insert(0, (request) async {
      if (!request.url.endsWith(path) || remaining <= 0) return null;
      remaining -= 1;
      return http.Response(jsonEncode(body), status);
    });
  }
}

void expectContract(Recorded? request, String name) {
  expect(request, isNotNull, reason: 'missing $name');
  final entry = spec(name);
  final body = entry['body'] as Map<String, dynamic>;
  if (entry['path'] != null) {
    expect(request!.url, '${contract['config']['apiBaseUrl']}${entry['path']}');
    (contract['headers'] as Map<String, dynamic>).forEach((header, value) {
      expect(request.headers[header]?.split(';').first, value, reason: 'header $header');
    });
  } else {
    expect(request!.url, entry['url']);
  }
  body.forEach((key, value) {
    if (key != 'events') expect(request.body[key], value, reason: 'body.$key');
  });
  for (final key in (entry['absentBodyFields'] as List).cast<String>()) {
    expect(request.body.containsKey(key), isFalse, reason: '$key should be absent');
  }
  final dynamicFields = (entry['dynamicBodyFields'] as List).cast<String>();
  for (final key in dynamicFields.where((field) => !field.contains('[]'))) {
    expect((request.body[key] as String?)?.isNotEmpty, isTrue, reason: '$key should be set');
  }
  final allowed = {...body.keys, ...dynamicFields, ...(entry['optionalBodyFields'] as List).cast<String>()};
  expect(request.body.keys.where((key) => !allowed.contains(key)), isEmpty);
}

void main() {
  group('screens, commerce, profile and signup', () {
    late Harness harness;
    setUp(() => harness = Harness());

    test('sends screens and commerce events as typed queue entries', () async {
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      await client.screen(' Pricing ', {'plan': 'pro'});
      await client.viewedProduct(const CommerceProduct(providerProductId: 'sku-1', title: 'Shoe'));
      await client
          .addedToCart(const CommerceCartLine(product: CommerceProduct(providerProductId: 'sku-1'), quantity: 2));
      await client.searched(' shoes ');
      await client.track('custom_thing');
      final events = harness
          .to('/api/v1/app-events')
          .map((request) => (request.body['events'] as List).single as Map<String, dynamic>)
          .toList();
      expect(events[0]['type'], 'screen');
      expect(events[0]['properties'], {'plan': 'pro', 'screen': 'Pricing'});
      expect(events[1]['type'], 'commerce');
      expect(events[1]['name'], 'product_viewed');
      expect((events[1]['properties'] as Map)['product'], {'providerProductId': 'sku-1', 'title': 'Shoe'});
      expect(((events[2]['properties'] as Map)['cartLine'] as Map)['quantity'], 2);
      expect(events[3]['properties'], {'searchQuery': 'shoes'});
      expect(events[4].containsKey('type'), isFalse);
    });

    test('ignores a screen without a name', () async {
      final client = harness.make();
      await client.screen('  ');
      expect(await client.queuedEventCount(), 0);
    });

    test('merges profile updates, sends them once identified and retries', () async {
      final client = harness.make();
      await client.setProfile(const ProfileUpdate(firstName: 'Jane', attributes: {'goal': 'run'}));
      await client.setProfile(const ProfileUpdate(attributes: {'level': 3}, clearLastName: true));
      expect(harness.to('/api/v1/app-attributes'), isEmpty);
      harness.respondTo('/api/v1/app-attributes', 503, {}, times: 1);
      await client.identify(email, identityToken: identityToken);
      expect(harness.to('/api/v1/app-attributes'), hasLength(1));
      final restarted = harness.make();
      harness.now = harness.now.add(const Duration(seconds: 2));
      await restarted.flush();
      final sent = harness.to('/api/v1/app-attributes');
      expect(sent, hasLength(2));
      expect(sent[1].body['firstName'], 'Jane');
      expect(sent[1].body.containsKey('lastName'), isTrue);
      expect(sent[1].body['lastName'], isNull);
      expect(sent[1].body['attributes'], {'goal': 'run', 'level': 3});
      await restarted.flush();
      expect(harness.to('/api/v1/app-attributes'), hasLength(2));
    });

    test('forgets a pending profile on reset', () async {
      final client = harness.make();
      await client.setProfile(const ProfileUpdate(firstName: 'Old'));
      await client.reset();
      await client.identify(email, identityToken: identityToken);
      expect(harness.to('/api/v1/app-attributes'), isEmpty);
    });

    test('subscribes through a form without identifying', () async {
      final client = harness.make();
      final result = await client.subscribe(const SubscribeRequest(
          formId: 'form_1', email: ' new@example.com ', firstName: 'Nia', phone: '+14155550123'));
      expect(result.ok, isTrue);
      final request = harness.to('/api/v1/app-subscribe').single;
      expect(request.body, {
        'companyId': contract['config']['companyId'],
        'publicKey': contract['config']['publicKey'],
        'formId': 'form_1',
        'email': 'new@example.com',
        'firstName': 'Nia',
        'phone': '+14155550123',
      });
      expect(await client.email(), isNull);
      harness.respondTo('/api/v1/app-subscribe', 429, {'error': 'Too many'}, times: 1);
      final limited = await client.subscribe(const SubscribeRequest(formId: 'form_1', email: 'a@b.co'));
      expect(limited.ok, isFalse);
      expect(limited.retryable, isTrue);
      expect(limited.error, 'Too many');
      final invalid = await client.subscribe(const SubscribeRequest(formId: 'form_1', email: 'nope'));
      expect(invalid.retryable, isFalse);
    });
  });
  late Harness harness;
  setUp(() => harness = Harness());

  group('contract', () {
    test('registers the device before and after identify', () async {
      final client = harness.make();
      await client.setPushToken(pushToken);
      expectContract(harness.requests.last, 'registerAnonymousDevice');
      final anonymousId = harness.requests.last.body['anonymousId'];

      await client.identify('Jane@Example.com ', identityToken: identityToken);
      final identified = harness.to('/api/v1/push/app-devices').last;
      expectContract(identified, 'registerIdentifiedDevice');
      expect(identified.body['anonymousId'], anonymousId);
      expect(identified.body['appVersion'], '1.0');
    });

    test('tracks events', () async {
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      await client.track('workout_completed', {'minutes': 30});
      final request = harness.to('/api/v1/app-events').last;
      expectContract(request, 'trackEvents');
      expect(request.body['events'], [
        {
          'name': 'workout_completed',
          'eventId': 'uuid-1',
          'properties': {'minutes': 30},
          'occurredAt': '2026-10-14T17:46:40.000Z',
        }
      ]);
      expect(await client.queuedEventCount(), 0);
    });

    test('fetches the feed and reports in-app events', () async {
      harness.respondTo('/api/v1/in-app/feed', 200, jsonDecode(fixture('feed-response.json')) as Object);
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      final messages = await client.fetchFeed(kind: 'message');
      expectContract(harness.to('/api/v1/in-app/feed').last, 'fetchFeed');
      expect(messages.map((message) => message.id), ['iam_modal', 'iam_banner', 'iam_primer', 'iam_card']);
      expect(messages[2].buttons[0].requestsPushPermission, isTrue);
      expect(messages[2].buttons[0].acts, isTrue);
      expect(messages[2].buttons[1].acts, isFalse);
      expect(messages[0].resolvedFormat, 'modal');
      expect(messages[0].buttons[0], const InAppButton(label: 'Upgrade', action: 'open_url', url: 'myapp://billing'));
      expect(messages[0].buttons[1].opensUrl, isFalse);
      expect(messages[0].style.fontFamilies, ['Inter', 'Arial']);
      expect(messages[0].data, {'campaign': 'trial'});
      expect(messages[1].resolvedPosition, 'top');
      expect(messages[3].isCard, isTrue);
      expect(messages[3].pinned, isTrue);

      expect(await client.report(InAppEventType.displayed, 'iam_modal'), isTrue);
      expectContract(harness.requests.last, 'reportInAppEvent');
    });

    test('unregisters on reset and forgets the user', () async {
      final client = harness.make();
      await client.setPushToken(pushToken);
      await client.identify(email, identityToken: identityToken);
      final before = await client.anonymousId();
      await client.reset();
      expectContract(harness.requests.last, 'removeDevice');
      expect(await client.anonymousId(), isNot(before));
      expect(await client.email(), isNull);
      expect(harness.store.values['identityToken'], isNull);
    });

    test('parses push payloads and reports clicks', () async {
      final apns = PushPayload.fromData(jsonDecode(fixture('push-payload-apns.json')) as Map);
      final fcm = PushPayload.fromData(jsonDecode(fixture('push-payload-fcm-data.json')) as Map);
      expect(apns, fcm);
      expect(apns!.url, 'myapp://orders/123');
      expect(PushPayload.fromData({'title': 'Other sender'}), isNull);
      expect(PushPayload.fromData(null), isNull);
      expect(PushPayload.fromData({'pushSendId': 'p', 'deviceId': 'd', 'clickToken': 't', 'eventsUrl': 'javascript:x'}),
          isNull);

      await harness.make().reportPush('clicked', apns);
      expectContract(harness.requests.last, 'reportPushClicked');
      expect(harness.requests.last.headers['x-sequenzy-key'], isNull);
    });
  });

  group('queue', () {
    test('sends events tracked before identify once identified', () async {
      final client = harness.make();
      await client.track('viewed_onboarding');
      expect(harness.to('/api/v1/app-events'), isEmpty);
      await client.identify(email, identityToken: identityToken);
      expect((harness.to('/api/v1/app-events').single.body['events'] as List).single['name'], 'viewed_onboarding');
    });

    test('persists, caps and batches the queue', () async {
      final first = harness.make();
      for (var index = 0; index < 105; index++) {
        await first.track('event_$index');
      }
      expect(await first.queuedEventCount(), 100);
      final second = harness.make();
      expect(await second.queuedEventCount(), 100);
      await second.identify(email, identityToken: identityToken);
      expect(harness.to('/api/v1/app-events').map((request) => (request.body['events'] as List).length),
          [20, 20, 20, 20, 20]);
    });

    test('keeps the batch and backs off on retryable failures', () async {
      harness.respondTo('/api/v1/app-events', 503, {}, times: 1);
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      await client.track('a');
      expect(await client.queuedEventCount(), 1);
      expect(harness.timers, hasLength(1));
      await client.flush();
      expect(harness.to('/api/v1/app-events'), hasLength(1));
      harness.now = harness.now.add(const Duration(seconds: 2));
      harness.timers.single();
      expect(await client.queuedEventCount(), 0);
      final ids = harness.to('/api/v1/app-events').map((request) => (request.body['events'] as List).single['eventId']);
      expect(ids.toSet(), hasLength(1));
    });

    test('treats network errors as retryable', () async {
      var failures = 1;
      harness.responders.insert(0, (request) async {
        if (request.url.endsWith('/api/v1/app-events') && failures-- > 0) {
          throw const SocketException('offline');
        }
        return null;
      });
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      await client.track('a');
      expect(await client.queuedEventCount(), 1);
      harness.now = harness.now.add(const Duration(seconds: 2));
      await client.flush();
      expect(await client.queuedEventCount(), 0);
    });

    test('drops batches on permanent failures and partial rejections', () async {
      harness.respondTo('/api/v1/app-events', 400, {'error': 'bad'}, times: 1);
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      await client.track('a');
      expect(await client.queuedEventCount(), 0);
      harness.respondTo(
          '/api/v1/app-events',
          202,
          {
            'success': true,
            'accepted': 0,
            'rejected': [
              {'index': 0, 'eventId': 'x', 'error': 'built-in'}
            ]
          },
          times: 1);
      await client.track('saas.purchase');
      expect(await client.queuedEventCount(), 0);
    });

    test('drops stale events and clears the queue when the user changes', () async {
      final client = harness.make();
      await client.track('old');
      harness.now = harness.now.add(SequenzyClient.maxEventAge + const Duration(seconds: 1));
      await client.identify(email, identityToken: identityToken);
      expect(harness.to('/api/v1/app-events'), isEmpty);
      harness.respondTo('/api/v1/app-events', 503, {});
      await client.track('jane_only');
      await client.identify('bob@example.com', identityToken: 'seq_wid_bob');
      expect(await client.queuedEventCount(), 0);
    });

    test('serializes concurrent calls in order', () async {
      final client = harness.make();
      await Future.wait([
        client.identify(email, identityToken: identityToken),
        client.track('a'),
        client.track('b'),
      ]);
      final names = harness
          .to('/api/v1/app-events')
          .expand((request) => (request.body['events'] as List).map((event) => event['name']));
      expect(names, ['a', 'b']);
    });
  });

  group('identity tokens', () {
    test('refreshes a rejected token once from the provider', () async {
      var calls = 0;
      harness.responders.insert(0, (request) async {
        if (!request.url.endsWith('/api/v1/app-events') || request.body['identityToken'] == 'seq_wid_fresh') {
          return null;
        }
        return http.Response('{"success":false,"code":"invalid_web_tracking_identity"}', 403);
      });
      final client = harness.make(provider: (requested) async {
        calls += 1;
        expect(requested, email);
        return 'seq_wid_fresh';
      });
      await client.identify(email, identityToken: 'seq_wid_expired');
      await client.track('a');
      expect(calls, 1);
      expect(await client.queuedEventCount(), 0);
    });

    test('uses the provider when identify has no token', () async {
      final client = harness.make(provider: (_) async => 'seq_wid_from_backend');
      await client.identify(email);
      await client.track('a');
      expect(harness.to('/api/v1/app-events').last.body['identityToken'], 'seq_wid_from_backend');
    });

    test('holds events after a rejection without a provider until the next identify', () async {
      harness.respondTo('/api/v1/app-events', 403, {'code': 'invalid_web_tracking_identity'}, times: 1);
      final client = harness.make();
      await client.identify(email, identityToken: 'seq_wid_expired');
      await client.track('a');
      await client.track('b');
      expect(harness.to('/api/v1/app-events'), hasLength(1));
      expect(await client.queuedEventCount(), 2);
      await client.identify(email, identityToken: identityToken);
      expect(await client.queuedEventCount(), 0);
    });

    test('requires identity for the feed', () async {
      await expectLater(harness.make().fetchFeed(),
          throwsA(isA<SequenzyException>().having((error) => error.code, 'code', 'not_identified')));
    });
  });

  group('input guards', () {
    test('drops events that cannot be sent instead of wedging the queue', () async {
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      await client.track('date', {'when': DateTime(2026)});
      await client.track('huge', {'blob': 'x' * 9000});
      expect(await client.queuedEventCount(), 0);
      await client.track('ok');
      expect(harness.to('/api/v1/app-events'), hasLength(1));
    });

    test('does not ask a failing provider again for a minute', () async {
      var calls = 0;
      final client = harness.make(provider: (_) async {
        calls += 1;
        throw StateError('backend down');
      });
      await client.identify(email);
      await client.track('a');
      await client.track('b');
      expect(calls, 1);
      harness.now = harness.now.add(SequenzyClient.providerRetryInterval + const Duration(seconds: 1));
      await client.flush();
      expect(calls, 2);
    });

    test('refuses FCM tokens on iOS', () async {
      await harness.make().setPushToken('dXk3:APA91b${'x' * 140}');
      expect(harness.to('/api/v1/push/app-devices'), isEmpty);
    });

    test('retries loading state after a storage read fails', () async {
      await harness.make().track('kept');
      final flaky = _FlakyStore(harness.store);
      final client = SequenzyClient(
        const SequenzyConfig(
            publicKey: 'k', companyId: 'c', appId: 'a', platform: 'ios', logLevel: SequenzyLogLevel.none),
        store: flaky,
        httpClient: harness.httpClient,
      );
      await expectLater(client.queuedEventCount(), throwsA(isA<StateError>()));
      expect(await client.queuedEventCount(), 1);
    });
  });

  group('push registration', () {
    test('throttles until the token or user changes', () async {
      final client = harness.make();
      await client.setPushToken(pushToken);
      await client.setPushToken(pushToken);
      await client.registerPushIfNeeded();
      expect(harness.to('/api/v1/push/app-devices'), hasLength(1));
      harness.now = harness.now.add(SequenzyClient.pushRefreshInterval + const Duration(seconds: 1));
      await client.registerPushIfNeeded();
      expect(harness.to('/api/v1/push/app-devices'), hasLength(2));
      await client.setPushToken('b${pushToken.substring(1)}');
      expect(harness.to('/api/v1/push/app-devices'), hasLength(3));
    });

    test('registers anonymously when the identity is rejected', () async {
      harness.respondTo('/api/v1/push/app-devices', 403, {'code': 'invalid_web_tracking_identity'}, times: 1);
      final client = harness.make();
      await client.identify(email, identityToken: 'seq_wid_expired');
      await client.setPushToken(pushToken);
      final registrations = harness.to('/api/v1/push/app-devices');
      expect(registrations, hasLength(2));
      expect(registrations[1].body.containsKey('email'), isFalse);
    });

    test('never registers tokens on web', () async {
      final client = harness.make(platform: 'web');
      await client.setPushToken(pushToken);
      expect(harness.requests, isEmpty);
    });
  });

  group('push permission', () {
    late Harness harness;
    setUp(() => harness = Harness());

    ({SequenzyPushPermission handler, Map<String, int> calls, List<PushPermissionStatus> status}) permission(
        PushPermissionStatus initial,
        [PushPermissionStatus? afterRequest]) {
      final status = [initial];
      final calls = {'request': 0, 'settings': 0};
      return (
        handler: SequenzyPushPermission(
          getStatus: () async => status[0],
          request: () async {
            calls['request'] = calls['request']! + 1;
            status[0] = afterRequest ?? status[0];
            return status[0];
          },
          openSettings: () async {
            calls['settings'] = calls['settings']! + 1;
          },
        ),
        calls: calls,
        status: status,
      );
    }

    test('sends the permission with registrations and registers again when it changes', () async {
      final p = permission(PushPermissionStatus.denied);
      final client = harness.make(pushPermission: p.handler);
      await client.identify(email, identityToken: identityToken);
      await client.setPushToken(pushToken);
      expectContract(harness.to('/api/v1/push/app-devices').last, 'registerDeviceWithPermission');
      final count = harness.to('/api/v1/push/app-devices').length;
      await client.registerPushIfNeeded();
      expect(harness.to('/api/v1/push/app-devices'), hasLength(count));
      p.status[0] = PushPermissionStatus.granted;
      await client.registerPushIfNeeded();
      expect(harness.to('/api/v1/push/app-devices'), hasLength(count + 1));
      expect(harness.to('/api/v1/push/app-devices').last.body['permission'], 'granted');
    });

    test('asks for push primers only when it can ask for permission', () async {
      harness.respondTo('/api/v1/in-app/feed', 200, {'messages': <Object>[]});
      final plain = harness.make();
      await plain.identify(email, identityToken: identityToken);
      await plain.fetchFeed(kind: 'message');
      expectContract(harness.to('/api/v1/in-app/feed').last, 'fetchFeed');
      expect(harness.to('/api/v1/in-app/feed').last.body.containsKey('actions'), isFalse);
      final able = harness.make(pushPermission: permission(PushPermissionStatus.notDetermined).handler);
      await able.fetchFeed(kind: 'message');
      expectContract(harness.to('/api/v1/in-app/feed').last, 'fetchFeedWithPushPrimers');
    });

    test('reports a primer click with the permission', () async {
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      await client.report(InAppEventType.clicked, 'iam_primer', pushPermission: PushPermissionStatus.granted);
      expectContract(harness.requests.last, 'reportPushPrimerClicked');
    });

    test('prompts when the OS allows it and sends a second denial to Settings', () async {
      var fallback = 0;
      Future<void> opener() async => fallback += 1;
      final fresh = permission(PushPermissionStatus.notDetermined, PushPermissionStatus.granted);
      expect(await harness.make(pushPermission: fresh.handler).requestPushPermission(opener),
          PushPermissionStatus.granted);
      expect(fresh.calls, {'request': 1, 'settings': 0});
      final off = permission(PushPermissionStatus.denied);
      expect(await harness.make(pushPermission: off.handler).requestPushPermission(opener), PushPermissionStatus.denied);
      expect(off.calls, {'request': 1, 'settings': 1});
      final allowed = permission(PushPermissionStatus.granted);
      expect(await harness.make(pushPermission: allowed.handler).requestPushPermission(opener),
          PushPermissionStatus.granted);
      expect(allowed.calls['request'], 0);
      expect(await harness.make().requestPushPermission(opener), isNull);
      expect(fallback, 0);
    });

    test('opens no iOS-only Settings URL on Android without an opener', () async {
      var fallback = 0;
      Future<void> opener() async => fallback += 1;
      final off = permission(PushPermissionStatus.denied);
      final handler = SequenzyPushPermission(getStatus: off.handler.getStatus, request: off.handler.request);
      final android = harness.make(platform: 'android', pushPermission: handler);
      expect(await android.requestPushPermission(opener), PushPermissionStatus.denied);
      expect(fallback, 0);
      final ios = harness.make(pushPermission: handler);
      expect(await ios.requestPushPermission(opener), PushPermissionStatus.denied);
      expect(fallback, 1);
    });

    test('reads Firebase Messaging and permission_handler status names', () {
      expect(PushPermissionStatus.fromName('authorized'), PushPermissionStatus.granted);
      expect(PushPermissionStatus.fromName('notDetermined'), PushPermissionStatus.notDetermined);
      expect(PushPermissionStatus.fromName('provisional'), PushPermissionStatus.provisional);
      expect(PushPermissionStatus.fromName('permanentlyDenied'), PushPermissionStatus.denied);
      expect(PushPermissionStatus.fromName('granted'), PushPermissionStatus.granted);
    });
  });

  group('Live Activity tokens', () {
    late Harness harness;
    setUp(() => harness = Harness());
    const path = '/api/v1/push/live-activities';
    const removePath = '/api/v1/push/live-activities/remove';
    String tokenOf(String name) => (spec(name)['body'] as Map)['token'] as String;
    LiveActivityToken pushToStart() => LiveActivityToken.pushToStart(
        activityType: 'DeliveryAttributes', token: tokenOf('registerLiveActivityPushToStart'));
    LiveActivityToken update() => LiveActivityToken.update(
        activityType: 'DeliveryAttributes', activityId: 'order-1234', token: tokenOf('registerLiveActivityUpdate'));

    test('registers push-to-start anonymously and update tokens for the contact', () async {
      final client = harness.make();
      await client.registerLiveActivityToken(LiveActivityToken.pushToStart(
          activityType: 'DeliveryAttributes', token: tokenOf('registerLiveActivityPushToStart').toUpperCase()));
      expectContract(harness.to(path).last, 'registerLiveActivityPushToStart');

      await client.identify(email, identityToken: identityToken);
      await client.setPushToken(pushToken);
      await client.registerLiveActivityToken(update());
      final request = harness.to(path).last;
      expectContract(request, 'registerLiveActivityUpdate');
      expect(request.body['deviceToken'], pushToken);
    });

    test('sends stored tokens again when a contact is identified', () async {
      final client = harness.make();
      await client.registerLiveActivityToken(pushToStart());
      await client.identify(email, identityToken: identityToken);
      expect(harness.to(path), hasLength(2));
      expect(harness.to(path)[1].body['email'], email);
      await client.identify(email);
      expect(harness.to(path), hasLength(2));
    });

    test('moves only push-to-start tokens when another user signs in without reset', () async {
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      await client.registerLiveActivityToken(pushToStart());
      await client.registerLiveActivityToken(update());
      final before = harness.to(path).length;
      await client.identify('bob@example.com', identityToken: 'seq_wid_bob');
      final resent = harness.to(path).sublist(before);
      expect(resent.map((request) => request.body['token']), [pushToStart().token]);
      expect(await client.liveActivityTokens(), [pushToStart()]);
    });

    test('keeps one token per type and activity, surviving a restart', () async {
      final client = harness.make();
      await client.registerLiveActivityToken(pushToStart());
      await client.registerLiveActivityToken(update());
      final rotated = LiveActivityToken.pushToStart(activityType: 'DeliveryAttributes', token: 'e' * 80);
      await client.registerLiveActivityToken(rotated);
      expect(await client.liveActivityTokens(), [update(), rotated]);
      expect(await harness.make().liveActivityTokens(), [update(), rotated]);
    });

    test('reports an ended activity once and forgets it', () async {
      final client = harness.make();
      await client.registerLiveActivityToken(update());
      await client.liveActivityEnded(update().token.toUpperCase());
      expectContract(harness.to(removePath).last, 'endLiveActivity');
      await client.liveActivityEnded(update().token);
      expect(harness.to(removePath), hasLength(1));
      expect(await client.liveActivityTokens(), isEmpty);
    });

    test('unlinks on reset and re-registers push-to-start for the new installation', () async {
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      await client.registerLiveActivityToken(pushToStart());
      await client.registerLiveActivityToken(update());
      final before = await client.anonymousId();
      await client.reset();
      final removals = harness.to(removePath);
      expect(removals.map((request) => request.body['token']).toSet(), {pushToStart().token, update().token});
      expect(removals.every((request) => request.body['unlinkSubscriber'] == true), isTrue);
      final last = harness.to(path).last;
      expect(last.body['token'], pushToStart().token);
      expect(last.body.containsKey('email'), isFalse);
      expect(last.body['anonymousId'], isNot(before));
      expect(await client.liveActivityTokens(), [pushToStart()]);
    });

    test('ignores invalid tokens and other platforms', () async {
      final client = harness.make();
      for (final invalid in [
        LiveActivityToken.update(activityType: 'DeliveryAttributes', activityId: '-x', token: 'a' * 80),
        LiveActivityToken.pushToStart(activityType: 'Delivery Attributes', token: 'a' * 80),
        LiveActivityToken.pushToStart(activityType: 'DeliveryAttributes', token: 'nothex'),
      ]) {
        expect(invalid.isValid, isFalse);
        await client.registerLiveActivityToken(invalid);
      }
      await harness.make(platform: 'android').registerLiveActivityToken(pushToStart());
      expect(harness.to(path), isEmpty);
      expect(await client.liveActivityTokens(), isEmpty);
    });

    test('drops corrupted stored entries', () {
      expect(LiveActivityToken.fromJson({'kind': 'update', 'activityType': 'A', 'token': 'a' * 80}), isNull);
      expect(LiveActivityToken.fromJson('x'), isNull);
      expect(LiveActivityToken.fromJson(pushToStart().toJson()), pushToStart());
    });
  });

  group('geofences', () {
    final geofences = contract['geofences'] as Map<String, dynamic>;

    test('fetches nearby geofences with a rounded position', () async {
      harness.respondTo('/api/v1/geofences/nearby', 200, geofences['nearbyResponse'] as Object);
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      final nearby = await client.fetchNearbyGeofences(
          51.5074, -0.1404, Geofencing.fetchLimit(Geofencing.defaultMaxRegionsIOS));
      expectContract(harness.to('/api/v1/geofences/nearby').last, 'fetchNearbyGeofences');
      expect(nearby.geofences.map((region) => region.id), ['geo_1', 'geo_2']);
      expect(nearby.geofences.first.radiusMeters, 200);
      expect(nearby.refreshRadiusMeters, 4200);
    });

    test('requires identity for nearby geofences', () async {
      final client = harness.make();
      await expectLater(
        client.fetchNearbyGeofences(51.5, -0.1, 19),
        throwsA(isA<SequenzyException>().having((error) => error.code, 'code', 'not_identified')),
      );
      expect(harness.to('/api/v1/geofences/nearby'), isEmpty);
    });

    test('reports transitions through the queue, debounced, never the refresh region', () async {
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      expect(await client.trackGeofenceTransition('geo_1', GeofenceTransition.enter), isTrue);
      final request = harness.to('/api/v1/app-events').last;
      expectContract(request, 'trackGeofenceTransition');
      final event = (request.body['events'] as List).single as Map<String, dynamic>;
      final expected = ((spec('trackGeofenceTransition')['body'] as Map)['events'] as List).single as Map;
      expected.forEach((key, value) => expect(event[key], value, reason: 'event.$key'));
      expect(event['occurredAt'], '2026-10-14T17:46:40.000Z');

      harness.now = harness.now.add(const Duration(seconds: 30));
      expect(await client.trackGeofenceTransition('geo_1', GeofenceTransition.enter), isFalse);
      expect(await client.trackGeofenceTransition('geo_1', GeofenceTransition.exit), isTrue);
      expect(await client.trackGeofenceTransition(GeofenceRegion.refreshRegionId, GeofenceTransition.exit), isFalse);
      harness.now = harness.now.add(const Duration(seconds: 61));
      expect(await client.trackGeofenceTransition('geo_1', GeofenceTransition.enter), isTrue);
      expect(harness.to('/api/v1/app-events'), hasLength(3));
    });

    test('keeps queued geofence events across restarts and forgets the debounce on reset', () async {
      harness.respondTo('/api/v1/app-events', 503, {'error': 'down'});
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      await client.trackGeofenceTransition('geo_2', GeofenceTransition.exit);
      harness.responders.clear();
      final restarted = harness.make();
      await restarted.flush();
      final event = (harness.to('/api/v1/app-events').last.body['events'] as List).single as Map;
      expect(event['transition'], 'exit');
      expect(event['geofenceId'], 'geo_2');

      await restarted.reset();
      await restarted.identify(email, identityToken: identityToken);
      expect(await restarted.trackGeofenceTransition('geo_2', GeofenceTransition.exit), isTrue);
    });

    test('drops transitions while nobody is identified', () async {
      final client = harness.make();
      expect(await client.trackGeofenceTransition('geo_1', GeofenceTransition.enter), isFalse);
      expect(await client.queuedEventCount(), 0);
    });

    test('does not debounce another contact by the previous one', () async {
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      expect(await client.trackGeofenceTransition('geo_1', GeofenceTransition.enter), isTrue);
      await client.identify('sam@example.com', identityToken: identityToken);
      expect(await client.trackGeofenceTransition('geo_1', GeofenceTransition.enter), isTrue);
    });

    test('hands identity credentials to native reporters, asking the provider when told to', () async {
      var calls = 0;
      final client = harness.make(provider: (email) async => 'seq_wid_fresh.${++calls}');
      expect(await client.identityCredentials(), isNull);
      await client.identify(email, identityToken: identityToken);
      expect(await client.identityCredentials(), (email: email, identityToken: identityToken));
      expect(calls, 0);
      expect(await client.identityCredentials(refresh: true), (email: email, identityToken: 'seq_wid_fresh.1'));
      expect(await client.identityCredentials(), (email: email, identityToken: 'seq_wid_fresh.1'));
      await client.reset();
      expect(await client.identityCredentials(), isNull);
    });

    test('plans the nearest geofences plus a refresh region and diffs changes', () {
      final nearby = NearbyGeofences.fromJson(geofences['nearbyResponse'] as Map<String, Object?>);
      final planned = Geofencing.plan(nearby, latitude: 51.5074, longitude: -0.1404, maxRegions: 2);
      expect(planned.map((region) => region.id), ['geo_1', geofences['refreshRegionId']]);
      expect(planned.last, const GeofenceRegion(
          id: GeofenceRegion.refreshRegionId, latitude: 51.5074, longitude: -0.1404, radiusMeters: 4200));
      final all = NearbyGeofences(geofences: nearby.geofences);
      expect(Geofencing.plan(all, latitude: 0, longitude: 0, maxRegions: 20).map((region) => region.id),
          ['geo_1', 'geo_2']);

      final moved = GeofenceRegion(id: 'geo_1', latitude: 1, longitude: 1, radiusMeters: 200);
      final changes = Geofencing.diff(planned, [moved, planned.last]);
      expect(changes.remove, ['geo_1']);
      expect(changes.add, [moved]);
      expect(Geofencing.fetchLimit(20), 19);
      expect(Geofencing.fetchLimit(1), 1);
      expect(Geofencing.fetchLimit(500), 99);
      expect(Geofencing.roundCoordinate(-0.1404), -0.14);
      expect(GeofenceRegion.fromJson(planned.first.toJson()), planned.first);
    });
  });
}

class _FlakyStore implements SequenzyStore {
  _FlakyStore(this.inner);
  final SequenzyStore inner;
  bool failNext = true;

  @override
  Future<String?> getString(String key) async {
    if (failNext) {
      failNext = false;
      throw StateError('storage locked');
    }
    return inner.getString(key);
  }

  @override
  Future<void> setString(String key, String? value) => inner.setString(key, value);

}
