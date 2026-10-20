# Sequenzy for Flutter

Identify contacts, track events, register push tokens and show in-app
messages and content cards from Flutter apps. Pure Dart. Full guide:
[Mobile SDKs](https://docs.sequenzy.com/concepts/mobile-sdks).

## Install

```yaml
dependencies:
  sequenzy_flutter: ^0.1.0
```

## Use

```dart
import 'package:sequenzy_flutter/sequenzy_flutter.dart';

Sequenzy.configure(SequenzyConfig(
  publicKey: 'seq_pk_...',            // key with your app IDs under Allowed app IDs
  companyId: 'your-company-id',
  appId: 'com.example.app',
  platform: Platform.isIOS ? 'ios' : 'android',
  identityTokenProvider: (email) => myBackend.sequenzyToken(email),
));

MaterialApp(builder: (context, child) => SequenzyInAppHost(child: child!), home: ...);

await Sequenzy.identify(user.email);           // after sign-in; false for an invalid email
Sequenzy.track('workout_completed', {'minutes': 30});
// iOS needs the APNs device token (Sequenzy sends through APNs), Android the FCM token.
final pushToken = Platform.isIOS
    ? await FirebaseMessaging.instance.getAPNSToken()
    : await FirebaseMessaging.instance.getToken();
if (pushToken != null) await Sequenzy.setPushToken(pushToken);
FirebaseMessaging.onMessageOpenedApp.listen((m) => Sequenzy.handleNotificationOpened(m.data));
await Sequenzy.reset();                        // on sign-out

final cards = InAppCardsController();          // inbox: cards, refresh(), markRead(), dismiss()
InAppCardView(card: card, onDismiss: cards.dismiss);
```

## Develop

```bash
flutter pub get && flutter analyze && flutter test
cd example && flutter run
```

Tests run against `../contract/fixtures`. Releases are published from Sequenzy's main repository with a `flutter-v<version>` tag
(see `mobile-sdks/RELEASING.md` there); this folder is copied to
`Sequenzy/sequenzy-flutter` on each release.
