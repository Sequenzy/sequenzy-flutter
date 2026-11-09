# Sequenzy for Flutter

The official Flutter SDK for [Sequenzy](https://sequenzy.com), the email
marketing platform for SaaS. Identify contacts, track events, register push tokens and show in-app
messages and content cards from Flutter apps. Pure Dart. Events from your app start the same
sequences as your emails, and push and in-app messages are steps in them.
Full guide: [Mobile SDKs](https://docs.sequenzy.com/concepts/mobile-sdks).

## Install

```yaml
dependencies:
  sequenzy_flutter: ^0.3.0
```

## Use

```dart
import 'package:sequenzy_flutter/sequenzy_flutter.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

Sequenzy.configure(SequenzyConfig(
  publicKey: 'seq_pk_...',            // key with your app IDs under Allowed app IDs
  companyId: 'your-company-id',
  appId: 'com.example.app',
  platform: Platform.isIOS ? 'ios' : 'android',
  identityTokenProvider: (email) => myBackend.sequenzyToken(email),
  // Optional: the IANA timezone (for example from flutter_timezone), so push
  // campaigns can deliver in each contact's local time.
  timezone: (await FlutterTimezone.getLocalTimezone()).identifier,
  // Optional: lets Sequenzy see who allows notifications and show push
  // primers (in-app messages that ask).
  pushPermission: SequenzyPushPermission(
    getStatus: () async => PushPermissionStatus.fromName(
        (await FirebaseMessaging.instance.getNotificationSettings()).authorizationStatus.name),
    request: () async => PushPermissionStatus.fromName(
        (await FirebaseMessaging.instance.requestPermission()).authorizationStatus.name),
    openSettings: () async => openAppSettings(), // Android, from permission_handler
  ),
));

MaterialApp(builder: (context, child) => SequenzyInAppHost(child: child!), home: ...);

await Sequenzy.identify(user.email);           // after sign-in; false for an invalid email
await Sequenzy.identifyUser(user.id);          // or by your user ID, for users without an email
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

iOS Live Activities need Swift for the widget and ActivityKit. Forward the
tokens your Swift code or plugin receives so your backend can start, update and
end activities through Sequenzy:

```dart
await Sequenzy.registerLiveActivityToken(
    LiveActivityToken.pushToStart(activityType: 'DeliveryAttributes', token: token));
await Sequenzy.registerLiveActivityToken(LiveActivityToken.update(
    activityType: 'DeliveryAttributes', activityId: 'order-1234', token: token));
await Sequenzy.liveActivityEnded(token);       // when the activity ends or is dismissed
```

On sign-out, end your running activities in native code before
`Sequenzy.reset()`, so the next person never sees them.

Android Live Updates take the same backend calls. The SDK keeps their state
and tokens; your notification plugin (for example flutter_local_notifications)
draws them:

```dart
await Sequenzy.observeLiveUpdates('DeliveryAttributes'); // at launch, on Android
// in FirebaseMessaging.onMessage and onBackgroundMessage (the background
// handler runs in its own isolate: call Sequenzy.configure there first):
final decision = await Sequenzy.handleLiveUpdate(message.data, canShow: notificationsAllowed);
if (decision != null && decision.shouldShow) {
  // post or update the notification for decision.activity!.activityId:
  // ongoing until activity.isEnded, removed at decision.dismissAt
}
await Sequenzy.liveUpdateDismissed(activityId); // when it is swiped away
```

`startLiveUpdate`, `updateLiveUpdate` and `endLiveUpdate` change one from the
app, and `onLiveUpdatesRemoved` in `SequenzyConfig` lists the notifications to
cancel after sign-out.

## Placements

Show in-app content inline, in a slot of your own layout, for a
[placement](https://docs.sequenzy.com/concepts/in-app-placements) defined in Sequenzy. The widget builds
nothing while the contact has nothing to show.

```dart
const SequenzyPlacement(placementId: 'home_hero');
// Or draw it yourself:
SequenzyPlacement(placementId: 'home_hero', builder: (context, item, placements) => MyHero(item));
```

## Geofencing

[`sequenzy_flutter_geofences`](./geofences) watches your
[geofences](https://docs.sequenzy.com/concepts/geofences) natively on iOS and
Android and reports visits of the signed-in contact, also while the app is not
running:

```dart
await SequenzyGeofences.start();                // after Sequenzy.configure
await SequenzyGeofences.requestAuthorization();
await SequenzyGeofences.enable();
```

Apps that monitor regions themselves call `Sequenzy.fetchNearbyGeofences` and
`Sequenzy.trackGeofenceTransition` instead.

## Custom HTML messages

[Custom HTML in-app messages](https://docs.sequenzy.com/concepts/in-app-html-messages) (surveys, Braze-style custom HTML) show
automatically through `webview_flutter`. Their JavaScript bridge closes the
message, opens links through `onOpenUrl`, and logs events and attributes for
the identified contact. Pass `showHtmlMessages: false` to `SequenzyInAppHost`
to leave them in the feed.

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

## Users without an email

For users who sign in without an email (a hidden Apple address, phone login),
mint the identity token for your user ID as `externalId` and call
`identifyUser` with the same ID (and the email, when you minted with it). Set
`userIdentityTokenProvider` to renew these tokens. See
[Users without an email](https://docs.sequenzy.com/concepts/mobile-sdks#users-without-an-email).
