import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models.dart';
import '../sequenzy.dart';
import 'in_app_message_view.dart';

/// Fetches the identified contact's in-app messages when the app comes to the
/// foreground and after identify, and shows them one at a time over [child].
///
/// Wrap your app's routes, for example with `MaterialApp(builder: (context,
/// child) => SequenzyInAppHost(child: child!))`.
class SequenzyInAppHost extends StatefulWidget {
  const SequenzyInAppHost({
    super.key,
    required this.child,
    this.shouldShow,
    this.onOpenUrl,
    this.refreshInterval = const Duration(minutes: 1),
  });

  final Widget child;

  /// Return false to keep a message from showing now; it is offered again later.
  final bool Function(InAppMessage message)? shouldShow;

  /// Return true when the app handled the URL itself.
  final bool Function(String url, InAppMessage message)? onOpenUrl;

  /// How often the feed is fetched while the app is in the foreground.
  final Duration refreshInterval;

  @override
  State<SequenzyInAppHost> createState() => _SequenzyInAppHostState();
}

class _SequenzyInAppHostState extends State<SequenzyInAppHost> with WidgetsBindingObserver {
  final _queue = <InAppMessage>[];
  final _shown = <String>{};
  InAppMessage? _current;
  DateTime? _lastFetch;
  StreamSubscription<SequenzyIdentityEvent>? _subscription;
  Timer? _poll;
  final _back = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPolling();
    _subscription = Sequenzy.identityEvents.listen((event) {
      if (event == SequenzyIdentityEvent.identified) {
        unawaited(_refresh(force: true));
      } else {
        setState(() {
          _queue.clear();
          _shown.clear();
          _current = null;
        });
      }
    });
    unawaited(_refresh(force: true));
  }

  // Poll while in the foreground so a message created by something the user
  // just did (a tracked event starting a sequence) shows up without leaving
  // the app.
  void _startPolling() {
    if (_poll != null || widget.refreshInterval <= Duration.zero) return;
    _poll = Timer.periodic(widget.refreshInterval, (_) => unawaited(_refresh(force: false)));
  }

  void _stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  @override
  void dispose() {
    _stopPolling();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _back.dispose();
    super.dispose();
  }

  // Android back closes a modal or fullscreen message. Limits: Flutter asks
  // the app's own navigator first, so on a pushed route back still pops that
  // route; and with predictive back enabled on the root route, Android closes
  // the app without asking Flutter.
  @override
  Future<bool> didPopRoute() async {
    final message = _current;
    if (message == null || message.resolvedFormat == 'banner') return false;
    _back.value++;
    return true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _stopPolling();
      return;
    }
    _startPolling();
    final client = Sequenzy.client;
    if (client == null) return;
    unawaited(client.flush());
    unawaited(client.registerPushIfNeeded());
    unawaited(_refresh(force: false));
  }

  Future<void> _refresh({required bool force}) async {
    if (Sequenzy.client == null) return;
    final now = DateTime.now();
    // 90%: a poll firing on the interval must not lose a cycle to a fetch
    // that ran a moment after it was scheduled.
    if (!force && _lastFetch != null && now.difference(_lastFetch!) < widget.refreshInterval * 0.9) return;
    _lastFetch = now;
    final List<InAppMessage> messages;
    try {
      messages = await Sequenzy.fetchMessages();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    for (final message in messages) {
      if (message.isCard || _shown.contains(message.id) || _current?.id == message.id) continue;
      if (_queue.any((queued) => queued.id == message.id)) continue;
      _queue.add(message);
    }
    _showNext();
  }

  void _showNext() {
    if (_current != null) return;
    while (_queue.isNotEmpty) {
      final next = _queue.removeAt(0);
      if (widget.shouldShow?.call(next) == false) continue;
      _shown.add(next.id);
      setState(() => _current = next);
      unawaited(Sequenzy.report(InAppEventType.displayed, next));
      return;
    }
  }

  void _close() {
    setState(() => _current = null);
    _showNext();
  }

  @override
  Widget build(BuildContext context) {
    final message = _current;
    return Stack(children: [
      widget.child,
      if (message != null)
        Positioned.fill(
          child: InAppMessageView(
            key: ValueKey(message.id),
            message: message,
            backRequests: _back,
            onDismiss: () {
              unawaited(Sequenzy.report(InAppEventType.dismissed, message));
              _close();
            },
            onPress: (button) {
              unawaited(Sequenzy.report(InAppEventType.clicked, message));
              final url = button?.url ??
                  message.buttons
                      .where((candidate) => candidate.opensUrl)
                      .map((candidate) => candidate.url)
                      .firstOrNull;
              if (url != null && widget.onOpenUrl?.call(url, message) != true) {
                unawaited(Sequenzy.urlOpener(url));
              }
              _close();
            },
          ),
        ),
    ]);
  }
}
