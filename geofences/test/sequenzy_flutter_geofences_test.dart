import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sequenzy_flutter/sequenzy_flutter.dart';
import 'package:sequenzy_flutter_geofences/sequenzy_flutter_geofences.dart';

const channel = MethodChannel('sequenzy_flutter_geofences');

String token(DateTime expiresAt) {
  final claims = base64Url
      .encode(utf8.encode(jsonEncode(
          {'companyId': 'company_1', 'email': 'jane@example.com', 'expiresAt': expiresAt.millisecondsSinceEpoch})))
      .replaceAll('=', '');
  return 'seq_wid_$claims.signature';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late int providerCalls;
  late bool rejectStoredToken;

  setUp(() {
    calls = [];
    providerCalls = 0;
    rejectStoredToken = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'authorization' || 'requestAuthorization' => 'whenInUse',
        'setIdentity' => rejectStoredToken && (call.arguments as Map)['identityToken'] == 'seq_wid_rejected.token',
        'status' => {
            'enabled': true,
            'authorization': 'always',
            'preciseLocation': true,
            'regionIds': ['geo_1', 'sequenzy.refresh'],
            'queuedEvents': 2,
            'maxRegions': 20,
          },
        _ => null,
      };
    });
    Sequenzy.unconfigure();
    final config = SequenzyConfig(
      publicKey: 'seq_pk_test',
      companyId: 'company_1',
      appId: 'com.example.app',
      platform: 'ios',
      apiBaseUrl: 'https://api.example.com',
      logLevel: SequenzyLogLevel.none,
      identityTokenProvider: (email) async => token(DateTime.now().add(Duration(days: 30 + ++providerCalls))),
    );
    Sequenzy.configure(
      config,
      client: SequenzyClient(
        config,
        store: MemoryStore(),
        // Syncing never needs the network; anything sent is answered here.
        httpClient: MockClient((request) async => http.Response('{"success":true}', 200)),
      ),
    );
  });

  tearDown(() async {
    await SequenzyGeofences.stop();
    messenger.setMockMethodCallHandler(channel, null);
    Sequenzy.unconfigure();
  });

  Map<Object?, Object?> lastArguments(String method) =>
      calls.lastWhere((call) => call.method == method).arguments as Map<Object?, Object?>;

  test('hands the configuration and no identity to the native side before identify', () async {
    await SequenzyGeofences.start();
    expect(lastArguments('configure'), {
      'apiBaseUrl': 'https://api.example.com',
      'companyId': 'company_1',
      'publicKey': 'seq_pk_test',
      'appId': 'com.example.app',
      'userAgent': 'sequenzy-flutter-geofences/$sequenzySdkVersion',
    });
    expect(lastArguments('setIdentity'), {'email': null, 'identityToken': null});
  });

  test('follows identify and reset, and keeps a long-lived token', () async {
    await SequenzyGeofences.start();
    final valid = token(DateTime.now().add(const Duration(days: 20)));
    expect(await Sequenzy.identify('jane@example.com', identityToken: valid), isTrue);
    await pumpEventQueue();
    expect(lastArguments('setIdentity'), {'email': 'jane@example.com', 'identityToken': valid});
    expect(providerCalls, 0);

    await Sequenzy.reset();
    await pumpEventQueue();
    expect(lastArguments('setIdentity'), {'email': null, 'identityToken': null});
  });

  test('replaces a token that expires soon, and a rejected one, through the provider', () async {
    final expiring = token(DateTime.now().add(const Duration(hours: 5)));
    await Sequenzy.identify('jane@example.com', identityToken: expiring);
    await SequenzyGeofences.start();
    expect(providerCalls, 1);
    final fresh = lastArguments('setIdentity')['identityToken'] as String;
    expect(fresh, isNot(expiring));

    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('identityRejected')),
      (_) {},
    );
    await pumpEventQueue();
    expect(providerCalls, 2);
    expect(lastArguments('setIdentity')['identityToken'], isNot(fresh));
  });

  test('enables with a region cap and reads status and authorization', () async {
    await SequenzyGeofences.enable(maxRegions: 10);
    expect(lastArguments('enable'), {'maxRegions': 10});
    expect(calls.map((call) => call.method), containsAllInOrder(['configure', 'setIdentity', 'enable']));
    expect(await SequenzyGeofences.requestAuthorization(), GeofenceAuthorization.whenInUse);
    expect(await SequenzyGeofences.authorization(), GeofenceAuthorization.whenInUse);
    final status = await SequenzyGeofences.status();
    expect(status.isMonitoring, isTrue);
    expect(status.regionIds, ['geo_1', 'sequenzy.refresh']);
    expect(status.queuedEvents, 2);
    expect(status.maxRegions, 20);
    await SequenzyGeofences.disable();
    await SequenzyGeofences.refresh();
    expect(calls.map((call) => call.method), containsAllInOrder(['disable', 'refresh']));
  });

  test('requires Sequenzy.configure first, and starts once it is configured', () async {
    final client = Sequenzy.client!;
    Sequenzy.unconfigure();
    await expectLater(SequenzyGeofences.start(), throwsA(isA<SequenzyException>()));
    Sequenzy.configure(client.config, client: client);
    await SequenzyGeofences.start();
    expect(lastArguments('setIdentity'), {'email': null, 'identityToken': null});
  });

  test('asks for a fresh token when the native side holds the stored one as rejected', () async {
    rejectStoredToken = true;
    await Sequenzy.identify('jane@example.com', identityToken: 'seq_wid_rejected.token');
    await SequenzyGeofences.start();
    expect(providerCalls, 1);
    expect(lastArguments('setIdentity')['identityToken'], isNot('seq_wid_rejected.token'));
  });

  test('reads token expiry and ignores tokens it cannot read', () {
    final expiresAt = DateTime.utc(2027, 1, 2, 3, 4, 5);
    expect(SequenzyGeofences.identityTokenExpiry(token(expiresAt)), expiresAt);
    expect(SequenzyGeofences.identityTokenExpiry('seq_wid_notbase64.sig'), isNull);
    expect(SequenzyGeofences.identityTokenExpiry('other'), isNull);
  });
}
