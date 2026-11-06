/// Geofence models and planning shared by the Sequenzy client and the
/// `sequenzy_flutter_geofences` plugin.
library;

/// A circular region from `POST /api/v1/geofences/nearby`, or the refresh
/// region the SDK adds around the device.
class GeofenceRegion {
  const GeofenceRegion({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
  });

  /// Registered around the device to know when to fetch again; never reported.
  static const refreshRegionId = 'sequenzy.refresh';

  final String id;
  final double latitude;
  final double longitude;
  final double radiusMeters;

  bool get isRefreshRegion => id == refreshRegionId;

  Map<String, Object?> toJson() => {
        'id': id,
        'latitude': latitude,
        'longitude': longitude,
        'radiusMeters': radiusMeters,
      };

  static GeofenceRegion? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final latitude = json['latitude'];
    final longitude = json['longitude'];
    final radius = json['radiusMeters'];
    if (id is! String || latitude is! num || longitude is! num || radius is! num) return null;
    return GeofenceRegion(
      id: id,
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
      radiusMeters: radius.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GeofenceRegion &&
      other.id == id &&
      other.latitude == latitude &&
      other.longitude == longitude &&
      other.radiusMeters == radiusMeters;

  @override
  int get hashCode => Object.hash(id, latitude, longitude, radiusMeters);

  @override
  String toString() => 'GeofenceRegion($id, $latitude, $longitude, ${radiusMeters}m)';
}

enum GeofenceTransition {
  enter('enter'),
  exit('exit');

  const GeofenceTransition(this.wire);
  final String wire;
}

/// The nearest active geofences and how far the device can move before
/// others come into reach.
class NearbyGeofences {
  const NearbyGeofences({required this.geofences, this.refreshRadiusMeters});

  final List<GeofenceRegion> geofences;

  /// Null when every geofence of the workspace was returned.
  final double? refreshRadiusMeters;

  static NearbyGeofences fromJson(Map<String, Object?>? json) {
    final list = json?['geofences'];
    final radius = json?['refreshRadiusMeters'];
    return NearbyGeofences(
      geofences: list is List ? list.map(GeofenceRegion.fromJson).whereType<GeofenceRegion>().toList() : const [],
      refreshRadiusMeters: radius is num ? radius.toDouble() : null,
    );
  }
}

/// Limits and planning rules every Sequenzy SDK uses.
abstract final class Geofencing {
  static const defaultMaxRegionsIOS = 20;
  static const defaultMaxRegionsAndroid = 50;
  static const debounce = Duration(seconds: 60);
  static const minRefreshInterval = Duration(seconds: 60);
  static const staleAfter = Duration(hours: 6);

  /// Two decimals, about 1.1 km.
  static double roundCoordinate(double value) => (value * 100).round() / 100;

  static int fetchLimit(int maxRegions) => (maxRegions - 1).clamp(1, 99);

  /// Returned geofences (at most `maxRegions - 1`) plus a refresh region on
  /// the precise device position when the server says more exist.
  static List<GeofenceRegion> plan(
    NearbyGeofences nearby, {
    required double latitude,
    required double longitude,
    required int maxRegions,
  }) {
    final regions = nearby.geofences.take(fetchLimit(maxRegions)).toList();
    final radius = nearby.refreshRadiusMeters;
    if (radius != null && radius > 0) {
      regions.add(GeofenceRegion(
        id: GeofenceRegion.refreshRegionId,
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radius,
      ));
    }
    return regions;
  }

  /// Only the regions that changed.
  static ({List<String> remove, List<GeofenceRegion> add}) diff(
    List<GeofenceRegion> registered,
    List<GeofenceRegion> planned,
  ) {
    final current = {for (final region in registered) region.id: region};
    final next = {for (final region in planned) region.id: region};
    return (
      remove: registered.where((region) => next[region.id] != region).map((region) => region.id).toList(),
      add: planned.where((region) => current[region.id] != region).toList(),
    );
  }
}
