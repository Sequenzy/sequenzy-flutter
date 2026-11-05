import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sequenzy_flutter/sequenzy_flutter.dart';

import 'client_test.dart' show Harness, expectContract, fixture, email, identityToken;

Map<String, Object?> describe(InAppHtmlBridgeMessage message) => switch (message) {
      InAppHtmlClose() => {'method': 'close'},
      InAppHtmlOpenUrl(:final url, :final external, :final buttonId) => {
          'method': 'openUrl',
          'url': url,
          'external': external,
          if (buttonId != null) 'buttonId': buttonId,
        },
      InAppHtmlLogClick(:final buttonId) => {'method': 'logClick', if (buttonId != null) 'buttonId': buttonId},
      InAppHtmlTrack(:final name, :final properties) => {'method': 'track', 'name': name, 'properties': properties},
      InAppHtmlSetAttributes(:final attributes) => {'method': 'setAttributes', 'attributes': attributes},
      InAppHtmlSetName(:final firstName, :final lastName) => {
          'method': 'setName',
          if (firstName != null) 'firstName': firstName,
          if (lastName != null) 'lastName': lastName,
        },
    };

void main() {
  final bridge = jsonDecode(fixture('in-app-html-bridge.json')) as Map<String, dynamic>;

  group('custom HTML bridge contract', () {
    test('parses the shared bridge messages', () {
      for (final entry in (bridge['valid'] as List).cast<Map<String, dynamic>>()) {
        final parsed = InAppHtmlBridgeMessage.parse(jsonEncode(entry['input']));
        expect(parsed, isNotNull, reason: '${entry['input']}');
        expect(describe(parsed!), entry['expected']);
      }
      for (final input in bridge['invalid'] as List) {
        expect(InAppHtmlBridgeMessage.parse(jsonEncode(input)), isNull, reason: '$input');
      }
      expect(InAppHtmlBridgeMessage.parse('not json'), isNull);
      expect(bridge['maxMessageBytes'], InAppHtmlBridgeMessage.maxMessageBytes);
      expect(bridge['maxCallsPerDisplay'], InAppHtmlBridgeMessage.maxCallsPerDisplay);
    });

    test('allows only https and app links', () {
      final urls = bridge['urls'] as Map<String, dynamic>;
      for (final url in urls['allowed'] as List) {
        expect(InAppHtmlBridgeMessage.isAllowedUrl(url as String), isTrue, reason: url);
      }
      for (final url in urls['blocked'] as List) {
        expect(InAppHtmlBridgeMessage.isAllowedUrl(url as String), isFalse, reason: url);
      }
    });
  });

  group('custom HTML feed', () {
    late Harness harness;
    setUp(() => harness = Harness());

    test('fetches html only when asked and reports button ids', () async {
      harness.respondTo('/api/v1/in-app/feed', 200, jsonDecode(fixture('feed-response-html.json')) as Object);
      final client = harness.make();
      await client.identify(email, identityToken: identityToken);
      final messages = await client.fetchFeed(kind: 'message', formats: const ['modal', 'banner', 'fullscreen', 'html']);
      expectContract(harness.to('/api/v1/in-app/feed').last, 'fetchFeedWithHtml');
      expect(messages.single.resolvedFormat, 'html');
      expect(messages.single.showCloseButton, isTrue);
      expect(messages.single.html, contains('brazeBridge.logClick'));

      expect(await client.report(InAppEventType.clicked, 'iam_html', buttonId: '0'), isTrue);
      expectContract(harness.requests.last, 'reportInAppHtmlClick');
      await client.report(InAppEventType.clicked, 'iam_html', buttonId: '<b>');
      expect(harness.requests.last.body.containsKey('buttonId'), isFalse);

      final native = InAppMessage.fromJson((jsonDecode(fixture('feed-response.json')) as Map)['messages'][0])!;
      expect(native.html, isNull);
      expect(native.showCloseButton, isFalse);
    });
  });

  group('InAppHtmlSession', () {
    late List<String> events;
    late List<InAppHtmlOutcome> outcomes;
    late List<InAppHtmlBridgeMessage> calls;
    InAppHtmlSession session() => InAppHtmlSession(
          onLoaded: () => events.add('loaded'),
          onBridge: calls.add,
          onFinish: outcomes.add,
        );
    String call(String method, [Map<String, Object?> args = const {}]) =>
        jsonEncode({'__sequenzyInApp': 1, 'method': method, 'args': args});

    setUp(() {
      events = [];
      outcomes = [];
      calls = [];
    });

    test('reports load once and hands app calls to the host', () {
      final current = session();
      current.pageFinished();
      current.pageFinished();
      expect(events, ['loaded']);
      current.receive(call('logClick', {'buttonId': 'q1'}));
      current.receive(call('track', {'name': 'nps', 'properties': {'score': 9}}));
      current.receive(call('eval'));
      expect(calls.map(describe), [
        {'method': 'logClick', 'buttonId': 'q1'},
        {'method': 'track', 'name': 'nps', 'properties': {'score': 9}},
      ]);
      current.receive(call('close'));
      current.receive(call('track', {'name': 'late'}));
      expect(outcomes.single, isA<InAppHtmlDismissed>());
      expect(calls, hasLength(2));
      current.dispose();
    });

    test('opens allowed links once and blocks others', () {
      final current = session();
      current.pageFinished();
      current.receive(call('openUrl', {'url': 'javascript:alert(1)'}));
      expect(outcomes, isEmpty);
      current.receive(call('openUrl', {'url': 'myapp://plans', 'buttonId': 'upgrade'}));
      final opened = outcomes.single as InAppHtmlOpened;
      expect(opened.url, 'myapp://plans');
      expect(opened.buttonId, 'upgrade');
      current.dispose();
    });

    test('lets the document and frames load and opens other main-frame navigations', () {
      final current = session();
      expect(current.allowNavigation(InAppHtmlBridgeMessage.baseUrl, isMainFrame: true), isTrue);
      expect(current.allowNavigation('about:blank', isMainFrame: true), isTrue);
      expect(current.allowNavigation('${InAppHtmlBridgeMessage.baseUrl}#step-2', isMainFrame: true), isTrue);
      expect(current.allowNavigation('https://player.example.com/embed', isMainFrame: false), isTrue);
      expect(current.allowNavigation('https://example.com/pricing', isMainFrame: true), isFalse);
      expect((outcomes.single as InAppHtmlOpened).url, 'https://example.com/pricing');
      current.dispose();
    });

    test('caps bridge calls per display', () {
      final current = session();
      current.pageFinished();
      for (var index = 0; index < InAppHtmlBridgeMessage.maxCallsPerDisplay + 10; index++) {
        current.receive(call('track', {'name': 'e$index'}));
      }
      expect(calls, hasLength(InAppHtmlBridgeMessage.maxCallsPerDisplay));
      current.dispose();
    });

    test('fails a document that never loads, without reporting it displayed', () {
      fakeAsync((async) {
        final current = session();
        async.elapse(const Duration(seconds: 11));
        expect(outcomes.single, isA<InAppHtmlFailed>());
        expect(events, isEmpty);
        current.pageFinished();
        expect(events, isEmpty);
      });
      final failed = session();
      failed.mainFrameFailed();
      expect(outcomes.last, isA<InAppHtmlFailed>());
      failed.dispose();
    });
  });
}
