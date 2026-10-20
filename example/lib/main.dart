import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:sequenzy_flutter/sequenzy_flutter.dart';

// Configure with --dart-define, e.g.
//   flutter run --dart-define=SEQUENZY_PUBLIC_KEY=seq_pk_... \
//     --dart-define=SEQUENZY_COMPANY_ID=... \
//     --dart-define=IDENTITY_TOKEN_URL=https://your-backend/identity-token
const publicKey = String.fromEnvironment('SEQUENZY_PUBLIC_KEY', defaultValue: 'seq_pk_replace_me');
const companyId = String.fromEnvironment('SEQUENZY_COMPANY_ID', defaultValue: 'replace-me');
const apiBaseUrl = String.fromEnvironment('SEQUENZY_API_URL', defaultValue: 'https://api.sequenzy.com');
// Your backend: POST { email } returns { identityToken } minted with your
// secret API key. Never ship the secret key in the app.
// A published Sequenzy form: its lists and opt-in settings apply.
const newsletterFormId = String.fromEnvironment('SEQUENZY_NEWSLETTER_FORM_ID', defaultValue: 'replace-me');
const identityTokenUrl = String.fromEnvironment('IDENTITY_TOKEN_URL', defaultValue: 'http://localhost:8787/identity-token');

String get platform => kIsWeb
    ? 'web'
    : defaultTargetPlatform == TargetPlatform.iOS
        ? 'ios'
        : 'android';

void main() {
  Sequenzy.configure(SequenzyConfig(
    publicKey: publicKey,
    companyId: companyId,
    appId: 'com.sequenzy.example',
    platform: platform,
    apiBaseUrl: apiBaseUrl,
    logLevel: SequenzyLogLevel.debug,
    identityTokenProvider: (email) async {
      final response = await http.post(
        Uri.parse(identityTokenUrl),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'email': email}),
      );
      return (jsonDecode(response.body) as Map<String, dynamic>)['identityToken'] as String;
    },
  ));
  // With firebase_messaging: use getToken() on Android and getAPNSToken() on iOS.
  // and Sequenzy.handleNotificationOpened(message.data) from onMessageOpenedApp.
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sequenzy example',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF0F172A), useMaterial3: true),
      builder: (context, child) => SequenzyInAppHost(child: child!),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _email = TextEditingController();
  final _cards = InAppCardsController();
  String? _signedIn;
  String _status = 'Not signed in';

  @override
  void initState() {
    super.initState();
    Sequenzy.client?.email().then((email) {
      if (email != null && mounted) {
        setState(() => _signedIn = email);
        _cards.refresh();
      }
    });
    _cards.addListener(() {
      for (final card in _cards.cards) {
        if (!card.isRead) _cards.markRead(card);
      }
    });
  }

  @override
  void dispose() {
    _cards.dispose();
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(padding: const EdgeInsets.all(24), children: [
              const Text('Sequenzy example', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              if (_signedIn == null) ...[
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    final identified = await Sequenzy.identify(_email.text);
                    setState(() {
                      _signedIn = identified ? _email.text.trim().toLowerCase() : null;
                      _status = identified ? 'Signed in' : 'Enter a valid email';
                    });
                  },
                  child: const Text('Sign in'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () async {
                    final result = await Sequenzy.subscribe(
                        SubscribeRequest(formId: newsletterFormId, email: _email.text));
                    setState(() => _status = result.ok ? 'Subscribed' : result.error ?? 'Could not subscribe');
                  },
                  child: const Text('Join the newsletter'),
                ),
              ] else ...[
                Text('Signed in as $_signedIn', style: const TextStyle(color: Color(0xFF64748B))),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () async {
                    await Sequenzy.track('workout_completed', {'count': 4, 'source': 'flutter-example'});
                    setState(() => _status = 'Tracked workout_completed');
                  },
                  child: const Text('Log a workout'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () async {
                    await Sequenzy.screen('Pricing', {'from': 'home'});
                    await Sequenzy.viewedProduct(const CommerceProduct(
                        providerProductId: 'plan-annual', title: 'Annual plan', price: 99, currency: 'USD'));
                    setState(() => _status = 'Sent a screen view and a product view');
                  },
                  child: const Text('Open pricing'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () async {
                    await Sequenzy.setProfile(const ProfileUpdate(firstName: 'Jane', attributes: {'goal': 'strength'}));
                    setState(() => _status = 'Updated the profile');
                  },
                  child: const Text('Set goal: strength'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () async {
                    await Sequenzy.reset();
                    setState(() {
                      _signedIn = null;
                      _status = 'Signed out';
                    });
                  },
                  child: const Text('Sign out'),
                ),
                const SizedBox(height: 24),
                const Text('Inbox', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                ListenableBuilder(
                  listenable: _cards,
                  builder: (context, _) {
                    if (_cards.loading && _cards.cards.isEmpty) return const Text('Loading cards…');
                    if (_cards.error != null) return Text('Could not load cards: ${_cards.error}');
                    if (_cards.cards.isEmpty) return const Text('No cards yet');
                    return Column(children: [
                      for (final card in _cards.cards)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: InAppCardView(card: card, onDismiss: _cards.dismiss),
                        ),
                    ]);
                  },
                ),
              ],
              const SizedBox(height: 12),
              Text(_status, style: const TextStyle(color: Color(0xFF64748B))),
            ]),
          ),
        ),
      ),
    );
  }
}
