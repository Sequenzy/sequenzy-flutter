import 'dart:async';

import 'package:flutter/widgets.dart';

import '../client.dart';
import '../models.dart';
import '../sequenzy.dart';
import 'in_app_card.dart';
import 'placement_item.dart';

/// What one placement shows now.
class PlacementState {
  const PlacementState({this.item, this.loading = true, this.error});

  /// Null when the slot should collapse.
  final InAppMessage? item;

  /// True until the first answer for the placement arrives.
  final bool loading;
  final Object? error;
}

/// Shared by every [SequenzyPlacement] in the app: one cache per placement
/// key, fetches batched across placements built in the same frame, and each
/// item reported displayed once per app session. Content belongs to one
/// contact: identifying someone else or resetting empties the cache, and
/// answers for the previous contact are dropped.
class SequenzyPlacements with WidgetsBindingObserver {
  SequenzyPlacements({
    Future<Map<String, InAppMessage?>> Function(List<String> keys)? fetch,
    Future<bool> Function(InAppEventType type, InAppMessage item)? report,
    Stream<SequenzyIdentityEvent>? identityEvents,
    Future<String?> Function()? identifiedEmail,
  })  : _fetch = fetch ?? Sequenzy.fetchPlacements,
        _report = report ?? ((type, item) => Sequenzy.report(type, item)),
        _identityEvents = identityEvents ?? Sequenzy.identityEvents,
        _identifiedEmail = identifiedEmail ?? Sequenzy.identifiedContact;

  static SequenzyPlacements? _shared;

  /// The instance [SequenzyPlacement] widgets use.
  static SequenzyPlacements get shared => _shared ??= SequenzyPlacements();

  final Future<Map<String, InAppMessage?>> Function(List<String> keys) _fetch;
  final Future<bool> Function(InAppEventType type, InAppMessage item) _report;
  final Stream<SequenzyIdentityEvent> _identityEvents;
  final Future<String?> Function() _identifiedEmail;

  final _states = <String, PlacementState>{};
  final _listeners = <String, Set<void Function(PlacementState)>>{};
  // Item ids are per contact, so these never need clearing.
  final _displayed = <String>{};
  // Dismissed this session: a fetch that raced the report must not bring the
  // item back.
  final _dismissed = <String>{};
  var _pending = <String>{};
  var _scheduled = false;
  var _generation = 0;
  // The newest request sent for each key: an older answer arriving later (a
  // refresh that was in flight during a dismissal) must not win.
  final _latestRequest = <String, int>{};
  var _requests = 0;
  DateTime _lastFetch = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<SequenzyIdentityEvent>? _subscription;
  // Who the cached content belongs to, once the first lookup finished.
  String? _contact;
  var _contactKnown = false;
  // Identity events wait for the first lookup, so an event for the contact
  // already signed in never empties the cache.
  Future<void> _contactLookup = Future<void>.value();

  static const _foregroundRefresh = Duration(minutes: 1);

  PlacementState get(String key) => _states[key] ?? const PlacementState();

  /// Follow a placement; the listener gets every change. Following a new
  /// placement fetches it. Returns a function that stops following.
  void Function() subscribe(String key, void Function(PlacementState) listener) {
    _attach();
    (_listeners[key] ??= {}).add(listener);
    if (!_states.containsKey(key)) _schedule([key]);
    return () {
      final set = _listeners[key];
      set?.remove(listener);
      if (set != null && set.isEmpty) _listeners.remove(key);
    };
  }

  /// Fetch [key] again, or every followed placement.
  void refresh([String? key]) => _schedule(key == null ? _listeners.keys.toList() : [key]);

  /// Report the item shown; once per item per app session.
  void logDisplayed(InAppMessage item) {
    if (!_displayed.add(item.id)) return;
    unawaited(_report(InAppEventType.displayed, item).catchError((_) => false));
  }

  /// Report a dismissal, empty the slot and ask for its next item.
  void dismiss(InAppMessage item) {
    _dismissed.add(item.id);
    final reported = _report(InAppEventType.dismissed, item).catchError((_) => false);
    final key = item.placement;
    if (key == null) return;
    if (_states[key]?.item?.id == item.id) _set(key, const PlacementState(loading: false));
    // Ask for the next item once the server has the dismissal: sooner, it
    // still answers with the dismissed item.
    unawaited(reported.whenComplete(() => _schedule([key])));
  }

  void _set(String key, PlacementState state) {
    _states[key] = state;
    for (final listener in [...?_listeners[key]]) {
      listener(state);
    }
  }

  void _schedule(Iterable<String> keys) {
    _pending.addAll(keys);
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      final batch = _pending.toList();
      _pending = {};
      if (batch.isNotEmpty) unawaited(_fetchKeys(batch));
    });
  }

  InAppMessage? _visible(InAppMessage? item) => item != null && !_dismissed.contains(item.id) ? item : null;

  Future<void> _fetchKeys(List<String> keys) async {
    final started = _generation;
    _lastFetch = DateTime.now();
    for (var at = 0; at < keys.length; at += SequenzyClient.maxPlacementsPerRequest) {
      final chunk = keys.sublist(at, (at + SequenzyClient.maxPlacementsPerRequest).clamp(0, keys.length));
      final request = ++_requests;
      for (final key in chunk) {
        _latestRequest[key] = request;
      }
      bool current(String key) => _latestRequest[key] == request;
      try {
        final items = await _fetch(chunk);
        if (started != _generation) return;
        for (final key in chunk.where(current)) {
          _set(key, PlacementState(item: _visible(items[key]), loading: false));
        }
      } catch (error) {
        if (started != _generation) return;
        // Keep what was showing; an empty slot stays collapsed.
        for (final key in chunk.where(current)) {
          _set(key, PlacementState(item: _states[key]?.item, loading: false, error: error));
        }
      }
    }
  }

  // Another contact's content must never show: empty every slot (cached ones
  // too, so a placement built later fetches instead of reusing it).
  void _forgetContent({required bool loading}) {
    _generation++;
    _pending = {};
    _states.clear();
    for (final key in _listeners.keys.toList()) {
      _set(key, PlacementState(loading: loading));
    }
  }

  // Listening for the app's whole life: an identity change while no
  // placement is on screen must still empty the cache.
  void _attach() {
    if (_subscription != null) return;
    // Future.sync: an unconfigured SDK throws synchronously; that must not
    // fail the widget's build.
    _contactLookup = Future.sync(_identifiedEmail).then((email) {
      if (!_contactKnown) {
        _contact = email;
        _contactKnown = true;
      }
    }).catchError((Object _) {});
    _subscription = _identityEvents.listen((event) {
      if (event == SequenzyIdentityEvent.reset) {
        _contact = null;
        _contactKnown = true;
        _forgetContent(loading: false);
        return;
      }
      unawaited(_contactLookup.then((_) => Future.sync(_identifiedEmail)).then((email) {
        if (!_contactKnown || email != _contact) {
          _contact = email;
          _contactKnown = true;
          _forgetContent(loading: true);
        }
        refresh();
      }).catchError((Object _) {
        refresh();
      }));
    });
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && DateTime.now().difference(_lastFetch) >= _foregroundRefresh) {
      refresh();
    }
  }
}

/// A slot in your layout that shows Sequenzy content for one placement,
/// drawn to mobile-sdks/DESIGN.md (the card layout without unread dot, pin
/// or close control). Builds nothing (zero size) when there is nothing to
/// show, so the slot collapses. Reports displayed once per item per session,
/// clicks and dismissals.
class SequenzyPlacement extends StatefulWidget {
  const SequenzyPlacement({
    super.key,
    required this.placementId,
    this.builder,
    this.onChanged,
    this.placements,
  });

  /// The placement key defined in Sequenzy, e.g. `home_hero`.
  final String placementId;

  /// Draw the item yourself; return the default [InAppCardView] otherwise.
  /// Only called when there is an item.
  final Widget Function(BuildContext context, InAppMessage item, SequenzyPlacements placements)? builder;

  /// Called when the slot's content changes; null when it collapses.
  final void Function(InAppMessage? item)? onChanged;

  /// Defaults to [SequenzyPlacements.shared].
  final SequenzyPlacements? placements;

  @override
  State<SequenzyPlacement> createState() => _SequenzyPlacementState();
}

class _SequenzyPlacementState extends State<SequenzyPlacement> {
  late SequenzyPlacements _placements;
  void Function()? _unsubscribe;
  PlacementState _state = const PlacementState();

  @override
  void initState() {
    super.initState();
    _follow();
  }

  @override
  void didUpdateWidget(SequenzyPlacement oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.placementId != widget.placementId || oldWidget.placements != widget.placements) {
      _unsubscribe?.call();
      _follow();
    }
  }

  void _follow() {
    _placements = widget.placements ?? SequenzyPlacements.shared;
    _state = _placements.get(widget.placementId);
    _unsubscribe = _placements.subscribe(widget.placementId, (state) {
      if (!mounted) return;
      final changed = state.item?.id != _state.item?.id;
      setState(() => _state = state);
      if (changed) widget.onChanged?.call(state.item);
    });
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = _state.item;
    if (item == null) return const SizedBox.shrink();
    _placements.logDisplayed(item);
    final builder = widget.builder;
    if (builder != null) return builder(context, item, _placements);
    return KeyedSubtree(
      key: Key('sequenzy-placement-${widget.placementId}'),
      child: item.resolvedLayout == 'card'
          ? InAppCardView(key: ValueKey(item.id), card: item, placement: true, onDismiss: _placements.dismiss)
          : PlacementItemView(
              item: item,
              onButton: (button) {
                if (button.acts) {
                  unawaited(Sequenzy.handleButtonPress(button, item));
                } else {
                  _placements.dismiss(item);
                }
              },
            ),
    );
  }
}
