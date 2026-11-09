// Android Live Updates: the FCM data messages Sequenzy sends for Live
// Activity starts, updates and ends, and the rules for applying them. The
// SDK keeps the state; your app draws the notification (for example with
// flutter_local_notifications) from the decision these return. Mirrors the
// Kotlin SDK's LiveUpdates.kt and the React Native live-updates.ts.

import 'dart:convert';

final _type = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$');
final _id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
final _token = RegExp(r'^[0-9a-f]{64,200}$');
final _digits = RegExp(r'^\d+$');

/// Ended Live Updates stay until dismissed, at most this long, as on iOS.
const liveUpdateEndedLinger = Duration(hours: 4);

/// Stored activities; the newest are kept, running ones first.
const maxLiveUpdateActivities = 32;

bool isLiveUpdateActivityType(String value) => _type.hasMatch(value);
bool isLiveUpdateActivityId(String value) => _id.hasMatch(value);

class LiveUpdateAlert {
  const LiveUpdateAlert({this.title, this.body, this.sound});
  final String? title;
  final String? body;
  final String? sound;
}

/// A Sequenzy Live Update push, parsed from FCM `RemoteMessage.data`.
class LiveUpdatePayload {
  const LiveUpdatePayload({
    required this.event,
    required this.activityType,
    required this.activityId,
    required this.timestamp,
    required this.contentState,
    this.attributes,
    this.alert,
    this.staleDate,
    this.dismissalDate,
    this.relevanceScore,
    this.updateToken,
  });

  /// `start`, `update` or `end`.
  final String event;
  final String activityType;
  final String activityId;

  /// Unix seconds; a push not newer than the last one applied is ignored.
  final int timestamp;
  final Map<String, Object?> contentState;

  /// Start only.
  final Map<String, Object?>? attributes;
  final LiveUpdateAlert? alert;

  /// Unix seconds after which the content is out of date.
  final int? staleDate;

  /// End only: Unix seconds when the notification should go away.
  final int? dismissalDate;
  final double? relevanceScore;

  /// Start only: the token Sequenzy registered for the new activity.
  final String? updateToken;

  LiveUpdatePayload copyWith({int? timestamp, int? dismissalDate, bool clearDismissalDate = false, String? updateToken, bool clearUpdateToken = false}) =>
      LiveUpdatePayload(
        event: event,
        activityType: activityType,
        activityId: activityId,
        timestamp: timestamp ?? this.timestamp,
        contentState: contentState,
        attributes: attributes,
        alert: alert,
        staleDate: staleDate,
        dismissalDate: clearDismissalDate ? null : dismissalDate ?? this.dismissalDate,
        relevanceScore: relevanceScore,
        updateToken: clearUpdateToken ? null : updateToken ?? this.updateToken,
      );

  /// Reads `RemoteMessage.data` from firebase_messaging (`onMessage` and
  /// `onBackgroundMessage`). Returns null for anything that is not a
  /// Sequenzy Live Update.
  static LiveUpdatePayload? fromData(Map<dynamic, dynamic> data) {
    String? text(String key) {
      final value = data[key];
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    int? integer(String key) {
      final value = text(key);
      return value != null && _digits.hasMatch(value) ? int.tryParse(value) : null;
    }

    if (text('sequenzyLiveUpdate') != '1') return null;
    final event = text('event');
    if (event != 'start' && event != 'update' && event != 'end') return null;
    final activityType = text('activityType');
    final activityId = text('activityId');
    final timestamp = integer('timestamp');
    final contentState = _object(text('contentState'));
    if (activityType == null ||
        !isLiveUpdateActivityType(activityType) ||
        activityId == null ||
        !isLiveUpdateActivityId(activityId) ||
        timestamp == null ||
        contentState == null) {
      return null;
    }
    final title = text('alertTitle');
    final body = text('alertBody');
    final token = text('updateToken')?.toLowerCase();
    final relevance = text('relevanceScore');
    return LiveUpdatePayload(
      event: event!,
      activityType: activityType,
      activityId: activityId,
      timestamp: timestamp,
      contentState: contentState,
      attributes: _object(text('attributes')),
      alert: title != null || body != null ? LiveUpdateAlert(title: title, body: body, sound: text('alertSound')) : null,
      staleDate: integer('staleDate'),
      dismissalDate: integer('dismissalDate'),
      relevanceScore: relevance == null ? null : double.tryParse(relevance),
      updateToken: token != null && _token.hasMatch(token) ? token : null,
    );
  }
}

Map<String, Object?>? _object(String? raw) {
  if (raw == null) return null;
  try {
    final value = jsonDecode(raw);
    return value is Map ? Map<String, Object?>.from(value) : null;
  } catch (_) {
    return null;
  }
}

/// One Live Update as your app draws it.
class LiveUpdateActivity {
  const LiveUpdateActivity({
    required this.activityType,
    required this.activityId,
    required this.attributes,
    required this.contentState,
    required this.staleDate,
    required this.isEnded,
  });

  final String activityType;
  final String activityId;

  /// Fixed when it started.
  final Map<String, Object?> attributes;
  final Map<String, Object?> contentState;
  final DateTime? staleDate;

  /// True once it ended: show the final content, not as ongoing.
  final bool isEnded;
}

/// What to do with a Live Update the SDK received or the app changed.
class LiveUpdateDecision {
  const LiveUpdateDecision.show(this.activity, {this.alert, this.dismissAt}) : reason = null;
  const LiveUpdateDecision.ignore(this.reason)
      : activity = null,
        alert = null,
        dismissAt = null;

  /// Set when the notification should be posted or updated.
  final LiveUpdateActivity? activity;
  final LiveUpdateAlert? alert;

  /// Ended activities: remove the notification at this time.
  final DateTime? dismissAt;

  /// Set when nothing changes: stale, unknown_activity, ended, dismissed, not_shown or invalid.
  final String? reason;

  bool get shouldShow => activity != null;
}

/// A Live Update this device shows or showed, as the SDK stores it.
class LiveUpdateRecord {
  const LiveUpdateRecord({
    required this.activityType,
    required this.activityId,
    required this.token,
    required this.attributes,
    required this.contentState,
    required this.timestamp,
    required this.state,
    this.staleDate,
  });

  final String activityType;
  final String activityId;
  final String token;
  final Map<String, Object?> attributes;
  final Map<String, Object?> contentState;
  final int timestamp;

  /// `active`, `ended` or `dismissed`.
  final String state;
  final int? staleDate;

  LiveUpdateRecord copyWith({Map<String, Object?>? contentState, int? timestamp, String? state, int? staleDate}) =>
      LiveUpdateRecord(
        activityType: activityType,
        activityId: activityId,
        token: token,
        attributes: attributes,
        contentState: contentState ?? this.contentState,
        timestamp: timestamp ?? this.timestamp,
        state: state ?? this.state,
        staleDate: staleDate ?? this.staleDate,
      );

  LiveUpdateActivity toActivity() => LiveUpdateActivity(
        activityType: activityType,
        activityId: activityId,
        attributes: attributes,
        contentState: contentState,
        staleDate: staleDate == null ? null : DateTime.fromMillisecondsSinceEpoch(staleDate! * 1000, isUtc: true),
        isEnded: state != 'active',
      );

  Map<String, Object?> toJson() => {
        'activityType': activityType,
        'activityId': activityId,
        'token': token,
        'attributes': attributes,
        'contentState': contentState,
        'timestamp': timestamp,
        'state': state,
        if (staleDate != null) 'staleDate': staleDate,
      };

  static LiveUpdateRecord? fromJson(Object? json) {
    if (json is! Map) return null;
    final state = json['state'];
    if (json['activityType'] is! String ||
        json['activityId'] is! String ||
        json['token'] is! String ||
        json['timestamp'] is! int ||
        !const ['active', 'ended', 'dismissed'].contains(state)) {
      return null;
    }
    return LiveUpdateRecord(
      activityType: json['activityType'] as String,
      activityId: json['activityId'] as String,
      token: json['token'] as String,
      attributes: json['attributes'] is Map ? Map<String, Object?>.from(json['attributes'] as Map) : const {},
      contentState: json['contentState'] is Map ? Map<String, Object?>.from(json['contentState'] as Map) : const {},
      timestamp: json['timestamp'] as int,
      state: state as String,
      staleDate: json['staleDate'] is int ? json['staleDate'] as int : null,
    );
  }
}

/// The result of one change: new records, what to show, and token work.
class LiveUpdateStep {
  const LiveUpdateStep(this.records, this.decision, {this.register, this.forget, this.remove});

  final List<LiveUpdateRecord> records;
  final LiveUpdateDecision decision;

  /// Update token record to store and register with Sequenzy.
  final LiveUpdateRecord? register;

  /// Token to forget locally (Sequenzy already knows it ended).
  final String? forget;

  /// Token to forget and report ended to Sequenzy.
  final String? remove;
}

List<LiveUpdateRecord> _save(List<LiveUpdateRecord> records, LiveUpdateRecord record) {
  final all = [...records.where((entry) => entry.activityId != record.activityId), record];
  final running = all.where((entry) => entry.state == 'active').toList();
  final finished = all.where((entry) => entry.state != 'active').toList();
  final room = (maxLiveUpdateActivities - running.length).clamp(0, maxLiveUpdateActivities);
  final kept = [...finished.skip((finished.length - room).clamp(0, finished.length)), ...running];
  return kept.length > maxLiveUpdateActivities ? kept.sublist(kept.length - maxLiveUpdateActivities) : kept;
}

LiveUpdateRecord? _find(List<LiveUpdateRecord> records, String activityId, {bool activeOnly = false}) {
  for (final record in records) {
    if (record.activityId == activityId && (!activeOnly || record.state == 'active')) return record;
  }
  return null;
}

/// Applies a received push. [canShow] is false when the app does not draw
/// this activity type or may not post notifications; a start is then
/// refused and reported ended, so Sequenzy does not count it as running.
LiveUpdateStep receiveLiveUpdate(
  List<LiveUpdateRecord> records,
  LiveUpdatePayload payload, {
  required bool canShow,
  required DateTime now,
  required String Function() newToken,
}) {
  final record = _find(records, payload.activityId);
  if (record != null && payload.timestamp <= record.timestamp) {
    return LiveUpdateStep(records, const LiveUpdateDecision.ignore('stale'));
  }
  if (payload.event == 'start') {
    if (!canShow) {
      return LiveUpdateStep(records, const LiveUpdateDecision.ignore('not_shown'), remove: payload.updateToken);
    }
    final next = LiveUpdateRecord(
      activityType: payload.activityType,
      activityId: payload.activityId,
      token: payload.updateToken ?? newToken(),
      attributes: payload.attributes ?? const {},
      contentState: payload.contentState,
      timestamp: payload.timestamp,
      state: 'active',
      staleDate: payload.staleDate,
    );
    return LiveUpdateStep(
      _save(records, next),
      LiveUpdateDecision.show(next.toActivity(), alert: payload.alert),
      register: next,
      forget: record != null && record.token != next.token ? record.token : null,
    );
  }
  if (record == null) {
    if (payload.event == 'update') return LiveUpdateStep(records, const LiveUpdateDecision.ignore('unknown_activity'));
    // FCM may deliver an end before its start: remember it, so the late
    // start is dropped as stale.
    final placeholder = LiveUpdateRecord(
      activityType: payload.activityType,
      activityId: payload.activityId,
      token: '',
      attributes: const {},
      contentState: payload.contentState,
      timestamp: payload.timestamp,
      state: 'ended',
    );
    return LiveUpdateStep(_save(records, placeholder), const LiveUpdateDecision.ignore('unknown_activity'));
  }
  if (record.state != 'active') return LiveUpdateStep(records, LiveUpdateDecision.ignore(record.state));
  if (payload.event == 'update') {
    if (!canShow) return LiveUpdateStep(records, const LiveUpdateDecision.ignore('not_shown'));
    final next = record.copyWith(
        contentState: payload.contentState, timestamp: payload.timestamp, staleDate: payload.staleDate);
    return LiveUpdateStep(_save(records, next), LiveUpdateDecision.show(next.toActivity(), alert: payload.alert));
  }
  final next = record.copyWith(contentState: payload.contentState, timestamp: payload.timestamp, state: 'ended');
  final dismissAt = payload.dismissalDate != null
      ? DateTime.fromMillisecondsSinceEpoch(payload.dismissalDate! * 1000, isUtc: true)
      : now.add(liveUpdateEndedLinger);
  return LiveUpdateStep(
    _save(records, next),
    LiveUpdateDecision.show(next.toActivity(), alert: payload.alert, dismissAt: dismissAt),
    // Sequenzy marked the token ended when FCM accepted the end.
    forget: record.token,
  );
}

/// Starts an activity from the app, so your backend can update and end it.
LiveUpdateStep startLiveUpdateLocally(
  List<LiveUpdateRecord> records, {
  required String activityType,
  required String activityId,
  required Map<String, Object?> attributes,
  required Map<String, Object?> contentState,
  required DateTime now,
  required String Function() newToken,
}) {
  if (!isLiveUpdateActivityType(activityType) || !isLiveUpdateActivityId(activityId)) {
    return LiveUpdateStep(records, const LiveUpdateDecision.ignore('invalid'));
  }
  final previous = _find(records, activityId);
  final next = LiveUpdateRecord(
    activityType: activityType,
    activityId: activityId,
    token: newToken(),
    attributes: attributes,
    contentState: contentState,
    // Pushes are ordered by the server's clock; app changes never move
    // that, so a fast device clock cannot hide updates.
    timestamp: previous?.timestamp ?? 0,
    state: 'active',
  );
  return LiveUpdateStep(_save(records, next), LiveUpdateDecision.show(next.toActivity()),
      register: next, forget: previous?.token);
}

LiveUpdateStep updateLiveUpdateLocally(
    List<LiveUpdateRecord> records, String activityId, Map<String, Object?> contentState, DateTime now) {
  final record = _find(records, activityId, activeOnly: true);
  if (record == null) return LiveUpdateStep(records, const LiveUpdateDecision.ignore('unknown_activity'));
  final next = record.copyWith(contentState: contentState);
  return LiveUpdateStep(_save(records, next), LiveUpdateDecision.show(next.toActivity()));
}

LiveUpdateStep endLiveUpdateLocally(List<LiveUpdateRecord> records, String activityId, DateTime now,
    {Map<String, Object?>? contentState, DateTime? dismissAt}) {
  final record = _find(records, activityId, activeOnly: true);
  if (record == null) return LiveUpdateStep(records, const LiveUpdateDecision.ignore('unknown_activity'));
  final next = record.copyWith(contentState: contentState, state: 'ended');
  return LiveUpdateStep(
    _save(records, next),
    LiveUpdateDecision.show(next.toActivity(), dismissAt: dismissAt ?? now.add(liveUpdateEndedLinger)),
    remove: record.token,
  );
}

/// The person swiped the notification away. Android asks apps not to post
/// it again, so later pushes are ignored and Sequenzy stops sending them.
LiveUpdateStep dismissLiveUpdate(List<LiveUpdateRecord> records, String activityId) {
  final record = _find(records, activityId);
  if (record == null || record.state == 'dismissed') {
    return LiveUpdateStep(records, const LiveUpdateDecision.ignore('unknown_activity'));
  }
  return LiveUpdateStep(
    _save(records, record.copyWith(state: 'dismissed')),
    const LiveUpdateDecision.ignore('dismissed'),
    remove: record.state == 'active' ? record.token : null,
  );
}
