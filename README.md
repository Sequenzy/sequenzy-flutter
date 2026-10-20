# Sequenzy for Flutter

The official Flutter SDK for [Sequenzy](https://sequenzy.com), the email
marketing platform for SaaS. Identify contacts, track events, register push tokens and show in-app
messages and content cards from Flutter apps. Pure Dart. Events from your app start the same
sequences as your emails, and push and in-app messages are steps in them.
Full guide: [Mobile SDKs](https://docs.sequenzy.com/concepts/mobile-sdks).

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

Tests run against `../contract/fixtures`. This repository is updated from Sequenzy's SDK
sources with every release.

## Links

- [Sequenzy](https://sequenzy.com): email marketing, push, SMS and in-app
  messages for SaaS, with automated sequences and AI-written emails.
- [Mobile SDK guide](https://docs.sequenzy.com/concepts/mobile-sdks)
- [Push notifications](https://docs.sequenzy.com/concepts/push-notifications)
  and [in-app messages](https://docs.sequenzy.com/concepts/in-app-messages)
- [Pricing](https://sequenzy.com/pricing)
- Other Sequenzy SDKs: [iOS](https://github.com/Sequenzy/sequenzy-swift), [Android](https://github.com/Sequenzy/sequenzy-android), [React Native](https://github.com/Sequenzy/sequenzy-react-native)
