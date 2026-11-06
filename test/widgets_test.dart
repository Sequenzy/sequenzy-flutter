import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sequenzy_flutter/sequenzy_flutter.dart';

final feed = jsonDecode(File('../contract/fixtures/feed-response.json').readAsStringSync()) as Map<String, dynamic>;

class Call {
  Call(this.path, this.body);
  final String path;
  final Map<String, dynamic> body;
}

void main() {
  late List<Call> calls;
  late List<String> opened;
  late List<dynamic> feedMessages;

  List<String> reports(String type) => calls
      .where((call) => call.path == '/api/v1/in-app/feed/events' && call.body['type'] == type)
      .map((call) => call.body['messageId'] as String)
      .toList();

  setUp(() {
    calls = [];
    opened = [];
    feedMessages = feed['messages'] as List;
    Sequenzy.unconfigure();
    Sequenzy.configure(
      const SequenzyConfig(
        publicKey: 'seq_pk_test',
        companyId: 'company_1',
        appId: 'com.example.app',
        platform: 'ios',
        logLevel: SequenzyLogLevel.none,
      ),
      client: SequenzyClient(
        const SequenzyConfig(
          publicKey: 'seq_pk_test',
          companyId: 'company_1',
          appId: 'com.example.app',
          platform: 'ios',
          logLevel: SequenzyLogLevel.none,
        ),
        store: MemoryStore(),
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          calls.add(Call(request.url.path, body));
          if (request.url.path == '/api/v1/in-app/feed') {
            // Like the API: push primers only for callers that list the action
            final canAsk = (body['actions'] as List?)?.contains('request_push_permission') ?? false;
            final messages = feedMessages.where((message) =>
                (body['kind'] == null || message['kind'] == body['kind']) &&
                (canAsk ||
                    !(message['buttons'] as List).any((button) => button['action'] == 'request_push_permission')));
            return http.Response(jsonEncode({'success': true, 'messages': messages.toList()}), 200);
          }
          return http.Response('{"success":true}', 200);
        }),
      ),
    );
    Sequenzy.urlOpener = (url) async => opened.add(url);
  });

  Future<void> pumpHost(WidgetTester tester, {bool Function(InAppMessage)? shouldShow}) async {
    await tester.runAsync(() => Sequenzy.identify('jane@example.com', identityToken: 'seq_wid_test'));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => SequenzyInAppHost(shouldShow: shouldShow, child: child!),
      home: const Scaffold(body: Text('Home')),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  Map<String, dynamic> modal(Map<String, dynamic> overrides) => {
        ...(feed['messages'] as List).first as Map<String, dynamic>,
        ...overrides,
      };

  Future<void> onPhone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('draws a bottom sheet on phones and closes it with an exit animation', (tester) async {
    await onPhone(tester);
    feedMessages = [
      modal({'imagePlacement': 'top'})
    ];
    await pumpHost(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sequenzy-sheet')), findsOneWidget);
    expect(find.text('3 days left'), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pump();
    // Still on screen while it slides away; reported once it is gone.
    expect(find.byKey(const Key('sequenzy-sheet')), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(reports('dismissed'), ['iam_modal']);
    expect(find.byKey(const Key('sequenzy-sheet')), findsNothing);
  });

  testWidgets('centers a dialog and falls back to the surface when its background image fails', (tester) async {
    await onPhone(tester);
    feedMessages = [
      modal({'position': 'center', 'imagePlacement': 'background'})
    ];
    await pumpHost(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sequenzy-modal')), findsOneWidget);
    // Test runs cannot load network images, so this exercises the fallback:
    // surface colors instead of white text on an empty gradient.
    final title = tester.widget<Text>(find.text('Welcome, Jane'));
    expect(title.textAlign, TextAlign.center);
    expect(title.style?.color, const Color(0xFF111827));
    expect(
      find.byWidgetPredicate((widget) =>
          widget is DecoratedBox &&
          widget.decoration is BoxDecoration &&
          (widget.decoration as BoxDecoration).gradient != null),
      findsNothing,
    );
  });

  testWidgets('makes the link primary and the dismiss button plain text', (tester) async {
    await onPhone(tester);
    feedMessages = [
      modal({'imagePlacement': 'top'})
    ];
    await pumpHost(tester);
    await tester.pumpAndSettle();
    final upgrade = tester.widget<Text>(find.text('Upgrade'));
    final later = tester.widget<Text>(find.text('Later'));
    expect(upgrade.style?.color, const Color(0xFFFFFFFF));
    expect(later.style?.color, const Color(0xFF4B5563));
    final primaryBox =
        tester.widget<Container>(find.ancestor(of: find.text('Upgrade'), matching: find.byType(Container)).first);
    expect((primaryBox.decoration as BoxDecoration).color, const Color(0xFF4F46E5));
  });

  group('push primers', () {
    Map<String, dynamic> primer() =>
        (feed['messages'] as List).cast<Map<String, dynamic>>().firstWhere((message) => message['id'] == 'iam_primer');

    void configureWithPermission(List<PushPermissionStatus> statuses, List<String> log) {
      var status = statuses.first;
      final permission = SequenzyPushPermission(
        getStatus: () async => status,
        request: () async {
          log.add('request');
          status = statuses.length > 1 ? statuses[1] : status;
          return status;
        },
        openSettings: () async => log.add('settings'),
      );
      final config = SequenzyConfig(
        publicKey: 'seq_pk_test',
        companyId: 'company_1',
        appId: 'com.example.app',
        platform: 'ios',
        logLevel: SequenzyLogLevel.none,
        pushPermission: permission,
      );
      Sequenzy.unconfigure();
      Sequenzy.configure(
        config,
        client: SequenzyClient(
          config,
          store: MemoryStore(),
          httpClient: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            calls.add(Call(request.url.path, body));
            if (request.url.path == '/api/v1/in-app/feed') {
              return http.Response(jsonEncode({'success': true, 'messages': feedMessages}), 200);
            }
            return http.Response('{"success":true}', 200);
          }),
        ),
      );
      Sequenzy.urlOpener = (url) async => opened.add(url);
    }

    testWidgets('never shows a primer to an app that cannot ask for permission', (tester) async {
      feedMessages = [primer()];
      await pumpHost(tester);
      expect(find.text('Turn on notifications'), findsNothing);
      expect(calls.firstWhere((call) => call.path == '/api/v1/in-app/feed').body.containsKey('actions'), isFalse);
    });

    testWidgets('asks for permission from the primer and reports the result with the click', (tester) async {
      final log = <String>[];
      configureWithPermission([PushPermissionStatus.notDetermined, PushPermissionStatus.granted], log);
      feedMessages = [primer()];
      await pumpHost(tester);
      expect(calls.firstWhere((call) => call.path == '/api/v1/in-app/feed').body['actions'],
          ['request_push_permission']);
      // The permission button is the filled primary one
      final primaryBox = tester.widget<Container>(
          find.ancestor(of: find.text('Turn on notifications'), matching: find.byType(Container)).first);
      expect((primaryBox.decoration as BoxDecoration).color, const Color(0xFF4F46E5));

      await tester.tap(find.text('Turn on notifications'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(log, ['request']);
      expect(opened, isEmpty);
      final click = calls.firstWhere(
          (call) => call.path == '/api/v1/in-app/feed/events' && call.body['type'] == 'clicked');
      expect(click.body['messageId'], 'iam_primer');
      expect(click.body['pushPermission'], 'granted');
      expect(find.text('Turn on notifications'), findsNothing);
    });

    testWidgets('opens notification settings when the contact turned them off', (tester) async {
      final log = <String>[];
      configureWithPermission([PushPermissionStatus.denied], log);
      await tester.runAsync(() async {
        await Sequenzy.identify('jane@example.com', identityToken: 'seq_wid_test');
        final message = InAppMessage.fromJson(primer())!;
        await Sequenzy.handleButtonPress(message.buttons.first, message);
      });
      expect(log, ['request', 'settings']);
      final click = calls.firstWhere((call) => call.path == '/api/v1/in-app/feed/events');
      expect(click.body['pushPermission'], 'denied');
    });
  });

  testWidgets('shows messages one at a time and reports displayed and dismissed', (tester) async {
    await pumpHost(tester);
    expect(find.byKey(const Key('sequenzy-modal')), findsOneWidget);
    expect(find.text('Welcome, Jane'), findsOneWidget);
    expect(find.text('Your trial ends in 3 days.'), findsOneWidget);
    expect(reports('displayed'), ['iam_modal']);

    await tester.tap(find.byKey(const Key('sequenzy-close')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(reports('dismissed'), ['iam_modal']);
    expect(find.byKey(const Key('sequenzy-banner')), findsOneWidget);
    expect(find.text('New: dark mode is here'), findsOneWidget);
    expect(reports('displayed'), ['iam_modal', 'iam_banner']);
    expect(find.byKey(const Key('sequenzy-card-iam_card')), findsNothing);
  });

  testWidgets("takes down the previous contact's messages after identify as someone else", (tester) async {
    await pumpHost(tester);
    expect(find.byKey(const Key('sequenzy-modal')), findsOneWidget);
    feedMessages = [];
    await tester.runAsync(() async {
      await Sequenzy.identify('bob@example.com', identityToken: 'seq_wid_bob');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.byKey(const Key('sequenzy-modal')), findsNothing);
    expect(find.byKey(const Key('sequenzy-banner')), findsNothing);
    expect(reports('dismissed'), isEmpty);
  });

  testWidgets('reports the click and opens the button URL', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('Upgrade'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(reports('clicked'), ['iam_modal']);
    expect(opened, ['myapp://billing']);
  });

  testWidgets('scrolls long copy instead of overflowing', (tester) async {
    await onPhone(tester);
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    feedMessages = [
      modal({'imagePlacement': 'top', 'position': 'center', 'body': List.filled(120, 'Long copy.').join(' ')})
    ];
    await pumpHost(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('sequenzy-modal-scroll')), findsOneWidget);
    final dialog = tester.getRect(find.byKey(const Key('sequenzy-modal')));
    expect(dialog.height, lessThanOrEqualTo(844 - 48));
    expect(find.byKey(const Key('sequenzy-close')).hitTestable(), findsOneWidget);
  });

  testWidgets('Android back closes a modal with its exit animation', (tester) async {
    await pumpHost(tester);
    await tester.pumpAndSettle();
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(reports('dismissed'), ['iam_modal']);
    // The banner that follows leaves back to the app.
    expect(find.byKey(const Key('sequenzy-banner')), findsOneWidget);
    expect(await tester.binding.handlePopRoute(), isFalse);
  });

  testWidgets('a dismiss button dismisses', (tester) async {
    await pumpHost(tester);
    await tester.tap(find.text('Later'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(reports('dismissed'), ['iam_modal']);
    expect(reports('clicked'), isEmpty);
  });

  testWidgets('lets the app veto a message', (tester) async {
    await pumpHost(tester, shouldShow: (message) => message.id != 'iam_modal');
    expect(find.byKey(const Key('sequenzy-modal')), findsNothing);
    expect(find.byKey(const Key('sequenzy-banner')), findsOneWidget);
    expect(reports('displayed'), ['iam_banner']);
  });

  testWidgets('cards list and dismiss through the controller once', (tester) async {
    await tester.runAsync(() => Sequenzy.identify('jane@example.com', identityToken: 'seq_wid_test'));
    final controller = InAppCardsController();
    await tester.runAsync(controller.refresh);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => ListView(children: [
            for (final card in controller.cards) InAppCardView(card: card, onDismiss: controller.dismiss),
          ]),
        ),
      ),
    ));
    expect(find.byKey(const Key('sequenzy-card-iam_card')), findsOneWidget);
    expect(find.text('Your weekly summary'), findsOneWidget);
    expect(
        find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == 'Pinned'), findsOneWidget);

    await tester.tap(find.descendant(
        of: find.byKey(const Key('sequenzy-card-iam_card')), matching: find.byKey(const Key('sequenzy-close'))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(reports('dismissed'), ['iam_card']);
    expect(find.byKey(const Key('sequenzy-card-iam_card')), findsNothing);
    controller.dispose();
  });

  test('markRead reports each card once even with stale copies', () async {
    await Sequenzy.identify('jane@example.com', identityToken: 'seq_wid_test');
    final controller = InAppCardsController();
    await controller.refresh();
    final stale = controller.cards.single;
    controller.markRead(stale);
    controller.markRead(stale);
    controller.markRead(controller.cards.single);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(reports('read'), ['iam_card']);
    expect(controller.cards.single.isRead, isTrue);
    controller.dispose();
  });

  test('identify reports success and only announces valid identities', () async {
    final events = <SequenzyIdentityEvent>[];
    final subscription = Sequenzy.identityEvents.listen(events.add);
    expect(await Sequenzy.identify('not-an-email'), isFalse);
    expect(await Sequenzy.identify(' Bob@Example.com ', identityToken: 'seq_wid_bob'), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(events, [SequenzyIdentityEvent.identified]);
    await subscription.cancel();
  });

  test('push helpers report Sequenzy notifications and ignore others', () async {
    final data =
        jsonDecode(File('../contract/fixtures/push-payload-fcm-data.json').readAsStringSync()) as Map<String, dynamic>;
    expect(await Sequenzy.handleNotificationOpened(data), isTrue);
    expect(opened, ['myapp://orders/123']);
    expect(calls.last.path, '/api/v1/push/events');
    expect(calls.last.body['type'], 'clicked');
    expect(await Sequenzy.handleNotificationReceived(data), isTrue);
    expect(calls.last.body['type'], 'delivered');
    expect(await Sequenzy.handleNotificationOpened({'title': 'Other'}), isFalse);
  });
}
