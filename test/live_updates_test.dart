import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sequenzy_flutter/sequenzy_flutter.dart';

final fixtures = Directory('../contract/fixtures');
Map<String, dynamic> read(String name) =>
    jsonDecode(File('${fixtures.path}/$name').readAsStringSync()) as Map<String, dynamic>;
final contract = read('requests.json');
final messages = read('live-update-fcm-data.json');
Map<String, dynamic> spec(String name) =>
    (contract['requests'] as List).cast<Map<String, dynamic>>().firstWhere((entry) => entry['name'] == name);
Map<String, dynamic> message(String name) =>
    (messages['messages'] as List).cast<Map<String, dynamic>>().firstWhere((entry) => entry['name'] == name);
Map<String, String> data(String name) => (message(name)['data'] as Map).cast<String, String>();
LiveUpdatePayload payload(String name) => LiveUpdatePayload.fromData(data(name))!;

const email = 'jane@example.com';
const identityToken = 'seq_wid_contract.token';
const fcmToken = 'fcm_contract_token';
const registerPath = '/api/v1/push/live-activities';
const removePath = '/api/v1/push/live-activities/remove';

/// One isolate's view of shared SharedPreferences: reads are cached until
/// [reload], as SharedPreferences does in each isolate.
class IsolateStore implements ReloadableSequenzyStore {
  IsolateStore(this.disk);
  final Map<String, String> disk;
  Map<String, String>? _cache;

  Map<String, String> get _values => _cache ??= Map.of(disk);

  @override
  Future<String?> getString(String key) async => _values[key];

  @override
  Future<void> setString(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
      disk.remove(key);
    } else {
      _values[key] = value;
      disk[key] = value;
    }
  }

  @override
  Future<void> reload() async => _cache = null;
}

class Harness {
  Harness([SequenzyStore? store]) : store = store ?? MemoryStore();
  final requests = <Map<String, dynamic>>[];
  final urls = <String>[];
  final SequenzyStore store;
  final removed = <List<String>>[];
  var now = DateTime.fromMillisecondsSinceEpoch(1792000050000, isUtc: true);
  var uuid = 0;

  late final http.Client httpClient = MockClient((request) async {
    urls.add(request.url.toString());
    requests.add(jsonDecode(request.body) as Map<String, dynamic>);
    if (request.url.path.endsWith('/api/v1/push/app-devices')) {
      return http.Response('{"success":true,"deviceId":"dev_1","identified":true,"pushConfigured":true}', 201);
    }
    return http.Response('{"success":true}', 200);
  });

  SequenzyClient make({String platform = 'android'}) {
    final config = contract['config'] as Map<String, dynamic>;
    return SequenzyClient(
      SequenzyConfig(
        publicKey: config['publicKey'] as String,
        companyId: config['companyId'] as String,
        appId: config['appId'] as String,
        apiBaseUrl: config['apiBaseUrl'] as String,
        platform: platform,
        logLevel: SequenzyLogLevel.none,
        appVersion: '1.0',
        osVersion: '16',
        onLiveUpdatesRemoved: removed.add,
      ),
      store: store,
      httpClient: httpClient,
      now: () => now,
      // 32 hex characters per call, like a UUID without dashes.
      uuid: () => (++uuid).toRadixString(16).padLeft(32, '0'),
      timer: (duration, callback) => Timer(const Duration(days: 1), () {}),
    );
  }

  List<Map<String, dynamic>> to(String path) => [
        for (var index = 0; index < urls.length; index += 1)
          if (urls[index].endsWith(path)) requests[index],
      ];
}

void expectContract(Map<String, dynamic>? body, String name) {
  expect(body, isNotNull, reason: 'missing $name');
  final entry = spec(name);
  (entry['body'] as Map<String, dynamic>).forEach((key, value) => expect(body![key], value, reason: 'body.$key'));
  for (final key in (entry['absentBodyFields'] as List).cast<String>()) {
    expect(body!.containsKey(key), isFalse, reason: '$key should be absent');
  }
  for (final key in (entry['dynamicBodyFields'] as List).cast<String>()) {
    expect(body![key], isNotNull, reason: '$key should be present');
  }
  final allowed = {
    ...(entry['body'] as Map).keys,
    ...(entry['dynamicBodyFields'] as List),
    ...(entry['optionalBodyFields'] as List),
  };
  expect(body!.keys.where((key) => !allowed.contains(key)), isEmpty);
}

void main() {
  group('LiveUpdatePayload.fromData', () {
    test('parses every message the server sends', () {
      for (final entry in (messages['messages'] as List).cast<Map<String, dynamic>>()) {
        final parsed = LiveUpdatePayload.fromData((entry['data'] as Map).cast<String, String>())!;
        final expected = entry['expected'] as Map<String, dynamic>;
        expect(parsed.event, expected['event']);
        expect(parsed.activityType, expected['activityType']);
        expect(parsed.activityId, expected['activityId']);
        expect(parsed.timestamp, expected['timestamp']);
        expect(parsed.contentState, expected['contentState']);
        expect(parsed.attributes, expected['attributes']);
        expect(parsed.alert?.title, (expected['alert'] as Map?)?['title']);
        expect(parsed.alert?.body, (expected['alert'] as Map?)?['body']);
        expect(parsed.staleDate, expected['staleDate']);
        expect(parsed.dismissalDate, expected['dismissalDate']);
        expect(parsed.relevanceScore, (expected['relevanceScore'] as num?)?.toDouble());
        expect(parsed.updateToken, expected['updateToken']);
      }
    });

    test('ignores everything else', () {
      for (final entry in (messages['ignored'] as List).cast<Map<String, dynamic>>()) {
        expect(LiveUpdatePayload.fromData((entry['data'] as Map).cast<String, String>()), isNull, reason: '${entry['name']}');
      }
      expect(LiveUpdatePayload.fromData({...data('start'), 'updateToken': 'nope'})!.updateToken, isNull);
    });
  });

  group('Live Update rules', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true);
    String newToken() => 'a' * 64;

    test('applies newer pushes only, then ends and ignores later updates', () {
      final started = receiveLiveUpdate([], payload('start'), canShow: true, now: now, newToken: newToken);
      expect(started.decision.shouldShow, isTrue);
      expect(started.decision.alert?.title, 'Order confirmed');
      expect(started.register?.token, payload('start').updateToken);

      expect(receiveLiveUpdate(started.records, payload('start'), canShow: true, now: now, newToken: newToken).decision.reason,
          'stale');
      final updated = receiveLiveUpdate(started.records, payload('update'), canShow: true, now: now, newToken: newToken);
      expect(updated.decision.activity!.contentState['status'], 'on the way');
      expect(updated.decision.activity!.attributes['orderNumber'], '1234');

      final ended = receiveLiveUpdate(updated.records, payload('end'), canShow: true, now: now, newToken: newToken);
      expect(ended.decision.activity!.isEnded, isTrue);
      expect(ended.decision.dismissAt!.millisecondsSinceEpoch, 1792000200000);
      expect(ended.forget, payload('start').updateToken);
      final late = payload('update').copyWith(timestamp: 1792000300);
      expect(receiveLiveUpdate(ended.records, late, canShow: true, now: now, newToken: newToken).decision.reason, 'ended');
    });

    test('lingers four hours after an end without a dismissal date', () {
      final started = receiveLiveUpdate([], payload('start'), canShow: true, now: now, newToken: newToken);
      final ended = receiveLiveUpdate(started.records, payload('end').copyWith(clearDismissalDate: true),
          canShow: true, now: now, newToken: newToken);
      expect(ended.decision.dismissAt, now.add(liveUpdateEndedLinger));
    });

    test('refuses a start it cannot show and reports its token', () {
      final step = receiveLiveUpdate([], payload('start'), canShow: false, now: now, newToken: newToken);
      expect(step.decision.reason, 'not_shown');
      expect(step.remove, payload('start').updateToken);
    });

    test('ignores updates for unknown, hidden or dismissed activities', () {
      expect(receiveLiveUpdate([], payload('update'), canShow: true, now: now, newToken: newToken).decision.reason,
          'unknown_activity');
      final started = receiveLiveUpdate([], payload('start'), canShow: true, now: now, newToken: newToken);
      expect(receiveLiveUpdate(started.records, payload('update'), canShow: false, now: now, newToken: newToken).decision.reason,
          'not_shown');
      final dismissed = dismissLiveUpdate(started.records, 'order-1234');
      expect(dismissed.remove, payload('start').updateToken);
      expect(receiveLiveUpdate(dismissed.records, payload('end'), canShow: true, now: now, newToken: newToken).decision.reason,
          'dismissed');
      expect(dismissLiveUpdate(dismissed.records, 'order-1234').remove, isNull);
    });

    test('keeps running activities when trimming', () {
      var records = startLiveUpdateLocally([],
              activityType: 'DeliveryAttributes',
              activityId: 'keep',
              attributes: const {},
              contentState: const {},
              now: now,
              newToken: newToken)
          .records;
      for (var index = 0; index < maxLiveUpdateActivities + 3; index += 1) {
        records = startLiveUpdateLocally(records,
                activityType: 'DeliveryAttributes',
                activityId: 'done-$index',
                attributes: const {},
                contentState: const {},
                now: now,
                newToken: newToken)
            .records;
        records = dismissLiveUpdate(records, 'done-$index').records;
      }
      expect(records, hasLength(maxLiveUpdateActivities));
      expect(records.any((record) => record.activityId == 'keep'), isTrue);
    });

    test('round-trips stored records and drops malformed ones', () {
      final started = receiveLiveUpdate([], payload('start'), canShow: true, now: now, newToken: newToken);
      final json = jsonDecode(jsonEncode(started.records.map((record) => record.toJson()).toList())) as List;
      final restored = json.map(LiveUpdateRecord.fromJson).whereType<LiveUpdateRecord>().toList();
      expect(restored.single.toActivity().staleDate!.millisecondsSinceEpoch, 1792003600000);
      expect(LiveUpdateRecord.fromJson({'activityId': 'a', 'state': 'paused'}), isNull);
      expect(LiveUpdateRecord.fromJson('x'), isNull);
    });
  });

  group('SequenzyClient Android Live Updates', () {
    late Harness harness;
    setUp(() => harness = Harness());

    test('registers a push-to-start token per observed type once the FCM token is known', () async {
      final client = harness.make();
      await client.observeLiveUpdates('DeliveryAttributes');
      expect(harness.to(registerPath), isEmpty);

      await client.setPushToken(fcmToken);
      final sent = harness.to(registerPath).single;
      expectContract(sent, 'registerLiveUpdatePushToStart');
      expect(sent['token'], matches(RegExp(r'^[0-9a-f]{64}$')));

      await client.observeLiveUpdates('DeliveryAttributes');
      expect(harness.to(registerPath).last['token'], sent['token']);
      await client.observeLiveUpdates('not a type');
      expect(await client.liveActivityTokens(), hasLength(1));
    });

    test('shows a pushed start and reports the token it carried for the contact', () async {
      final client = harness.make();
      await client.setPushToken(fcmToken);
      await client.identify(email, identityToken: identityToken);

      final decision = await client.handleLiveUpdate(data('start'));

      expect(decision!.shouldShow, isTrue);
      expectContract(harness.to(registerPath).last, 'registerLiveUpdateActivity');
      expect(await client.liveUpdates(), hasLength(1));
      expect(await client.handleLiveUpdate({'title': 'regular push'}), isNull);
      expect(await harness.make().liveUpdates(), hasLength(1));
    });

    test('starts, updates and ends an activity from the app', () async {
      final client = harness.make();
      await client.setPushToken(fcmToken);
      final started = await client
          .startLiveUpdate(activityType: 'DeliveryAttributes', activityId: 'order-9', contentState: {'status': 'placed'});
      expect(started.shouldShow, isTrue);
      final registered = harness.to(registerPath).last;
      expect(registered['kind'], 'update');
      expect(registered['platform'], 'android');

      final updated = await client.updateLiveUpdate('order-9', {'status': 'packed'});
      expect(updated.activity!.contentState['status'], 'packed');
      final ended = await client.endLiveUpdate('order-9', dismissAt: DateTime.utc(2030));
      expect(ended.dismissAt, DateTime.utc(2030));
      expect(harness.to(removePath).last['token'], registered['token']);
      expect(await client.liveActivityTokens(), isEmpty);
    });

    test('reports a dismissed activity', () async {
      final client = harness.make();
      await client.setPushToken(fcmToken);
      await client.handleLiveUpdate(data('start'));
      await client.liveUpdateDismissed('order-1234');
      expect(harness.to(removePath).last['token'], payload('start').updateToken);
      expect((await client.handleLiveUpdate(data('update')))!.reason, 'dismissed');
    });

    test('unlinks on reset and relinks with the next device registration', () async {
      final client = harness.make();
      await client.setPushToken(fcmToken);
      await client.identify(email, identityToken: identityToken);
      await client.observeLiveUpdates('DeliveryAttributes');
      await client.handleLiveUpdate(data('start'));
      final pushToStart = (await client.liveActivityTokens()).first;
      final before = harness.to(registerPath).length;

      await client.reset();

      expect(harness.removed, [
        ['order-1234']
      ]);
      expect(harness.to(removePath).every((body) => body['unlinkSubscriber'] == true), isTrue);
      expect(harness.to(registerPath), hasLength(before));
      await client.registerPushIfNeeded();
      final relinked = harness.to(registerPath).last;
      expect(relinked['token'], pushToStart.token);
      expect(relinked.containsKey('email'), isFalse);
    });

    test('keeps only push-to-start tokens when another person signs in', () async {
      final client = harness.make();
      await client.setPushToken(fcmToken);
      await client.identify(email, identityToken: identityToken);
      await client.observeLiveUpdates('DeliveryAttributes');
      await client.handleLiveUpdate(data('start'));
      final before = harness.to(registerPath).length;

      await client.identify('sam@example.com', identityToken: 'seq_wid_sam');

      expect(harness.removed, [
        ['order-1234']
      ]);
      final sent = harness.to(registerPath).sublist(before);
      expect(sent.map((body) => body['kind']), ['push_to_start']);
      expect(sent.single['email'], 'sam@example.com');
    });

    test('keeps Live Update methods to Android', () async {
      final client = harness.make(platform: 'ios');
      await client.observeLiveUpdates('DeliveryAttributes');
      expect((await client.startLiveUpdate(activityType: 'DeliveryAttributes', activityId: 'a')).reason, 'invalid');
      expect(await client.liveActivityTokens(), isEmpty);
    });

    test('never hides backend pushes behind app changes, even with a fast device clock', () async {
      final client = harness.make();
      harness.now = DateTime.fromMillisecondsSinceEpoch(1792003600000, isUtc: true);
      await client.startLiveUpdate(activityType: 'DeliveryAttributes', activityId: 'order-1234');
      await client.updateLiveUpdate('order-1234', {'status': 'app'});
      final decision = await client.handleLiveUpdate(data('update'));
      expect(decision!.activity!.contentState['status'], 'on the way');
    });

    test('drops a start that arrives after its end', () async {
      final client = harness.make();
      expect((await client.handleLiveUpdate(data('end')))!.reason, 'unknown_activity');
      expect((await client.handleLiveUpdate(data('start')))!.reason, 'stale');
    });

    test('removes ended notifications on reset too', () async {
      final client = harness.make();
      await client.handleLiveUpdate(data('start'));
      await client.handleLiveUpdate(data('end'));
      await client.reset();
      expect(harness.removed, [
        ['order-1234']
      ]);
    });

    test("unlinks the previous person's tokens on the server when another person signs in", () async {
      final client = harness.make();
      await client.setPushToken(fcmToken);
      await client.identify(email, identityToken: identityToken);
      await client.observeLiveUpdates('DeliveryAttributes');
      await client.handleLiveUpdate(data('start'));
      await client.identify('sam@example.com', identityToken: 'seq_wid_sam');
      final removals = harness.to(removePath);
      expect(removals, hasLength(2));
      expect(removals.every((body) => body['unlinkSubscriber'] == true), isTrue);
    });

    test('keeps push-to-start tokens when trimming', () async {
      final client = harness.make();
      await client.setPushToken(fcmToken);
      await client.observeLiveUpdates('DeliveryAttributes');
      for (var index = 0; index < 40; index += 1) {
        await client.startLiveUpdate(activityType: 'DeliveryAttributes', activityId: 'order-$index');
      }
      final tokens = await client.liveActivityTokens();
      expect(tokens, hasLength(32));
      expect(tokens.where((token) => token.kind == 'push_to_start'), hasLength(1));
    });

    test('sees a start the background isolate handled, and unlinks it on reset', () async {
      final disk = <String, String>{};
      final main = Harness(IsolateStore(disk));
      final background = Harness(IsolateStore(disk));
      final app = main.make();
      await app.setPushToken(fcmToken);
      expect(await app.liveUpdates(), isEmpty);

      // firebase_messaging's background isolate configures its own client.
      final handler = background.make();
      await handler.handleLiveUpdate(data('start'));

      expect(await app.liveUpdates(), hasLength(1));
      expect((await app.handleLiveUpdate(data('update')))!.shouldShow, isTrue);
      await app.reset();
      expect(main.removed, [
        ['order-1234']
      ]);
      expect(main.to(removePath).map((body) => body['token']), contains(payload('start').updateToken));
    });
  });
}
