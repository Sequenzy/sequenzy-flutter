# Sequenzy geofencing for Flutter

Reports when the signed-in contact enters or leaves your
[Sequenzy geofences](https://docs.sequenzy.com/concepts/geofences), so visits
can start sequences and build segments. Region monitoring is native (Core
Location on iOS, Google Play services on Android) and keeps working while the
app is in the background or not running.

## Install

```yaml
dependencies:
  sequenzy_flutter: ^0.3.0
  sequenzy_flutter_geofences: ^0.3.0
```

iOS 13+: add `NSLocationWhenInUseUsageDescription` and
`NSLocationAlwaysAndWhenInUseUsageDescription` to `ios/Runner/Info.plist`.
Android: the plugin declares fine, coarse and background location; Google
Play asks apps that use background location for a declaration.

## Use

```dart
Sequenzy.configure(SequenzyConfig(...));
await SequenzyGeofences.start(); // every launch, after configure

// Once the user agreed to location-based messages:
await SequenzyGeofences.requestAuthorization(); // "While using", then "Always"
await SequenzyGeofences.enable();

await SequenzyGeofences.disable(); // the user withdrew consent
final status = await SequenzyGeofences.status();
```

Only identified contacts are tracked: nothing is watched or sent until
`Sequenzy.identify` succeeds, and `Sequenzy.reset` stops it. Geofencing needs
"Always" access with precise location. The plugin registers the nearest
geofences (19 on iOS, 49 on Android; lower with `enable(maxRegions: ...)`
when the app watches regions of its own) plus one region around the device,
and fetches the next ones when the device leaves it.

Native code reports transitions itself while Dart is not running, with the
identity token the plugin last handed it. Configure an
`identityTokenProvider`: tokens that expire within three days, or that the
server rejects, are replaced through it. A visit recorded without a
connection is sent with the next visit, or when the app starts or opens,
within 24 hours.

Apps that monitor regions themselves can skip this plugin and call
`Sequenzy.fetchNearbyGeofences` and `Sequenzy.trackGeofenceTransition` from
`sequenzy_flutter`.

## Links

- [Geofences guide](https://docs.sequenzy.com/concepts/geofences)
- [Mobile SDKs guide](https://docs.sequenzy.com/concepts/mobile-sdks)
- [sequenzy_flutter](https://pub.dev/packages/sequenzy_flutter)
