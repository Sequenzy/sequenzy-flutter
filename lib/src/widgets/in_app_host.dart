import 'dart:async';

import 'package:flutter/widgets.dart';

import '../in_app_html.dart';
import '../models.dart';
import '../sequenzy.dart';
import 'in_app_html_view.dart';
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
    this.showHtmlMessages = true,
  });

  final Widget child;

  /// Return false to keep a message from showing now; it is offered again later.
  final bool Function(InAppMessage message)? shouldShow;

  /// Return true when the app handled the URL itself.
  final bool Function(String url, InAppMessage message)? onOpenUrl;

  /// How often the feed is fetched while the app is in the foreground.
  final Duration refreshInterval;

  /// Show custom HTML in-app messages (surveys, Braze-style custom HTML) in a
  /// WebView. When false they stay in the feed for another app version.
  final bool showHtmlMessages;

  @override
  State<SequenzyInAppHost> createState() => _SequenzyInAppHostState();
}

class _SequenzyInAppHostState extends State<SequenzyInAppHost> with WidgetsBindingObserver {
  final _queue = <InAppMessage>[];
  final _shown = <String>{};
  InAppMessage? _current;
  // The contact the queued and shown messages were fetched for.
  String? _owner;
  DateTime? _lastFetch;
  StreamSubscription<SequenzyIdentityEvent>? _subscription;
  Timer? _poll;
  final _back = ValueNotifier<int>(0);

  // An html message ignores back until its document has loaded, so back
  // must reach the app until then.
  bool _htmlLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startPolling();
    _subscription = Sequenzy.identityEvents.listen((event) {
      if (event == SequenzyIdentityEvent.identified) {
        unawaited(_refresh(force: true));
      } else {
        _clearMessages();
        _owner = null;
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
    if (message.resolvedFormat == 'html' && !_htmlLoaded) return false;
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

  void _clearMessages() {
    setState(() {
      _queue.clear();
      _shown.clear();
      _current = null;
    });
  }

  Future<void> _refresh({required bool force}) async {
    final client = Sequenzy.client;
    if (client == null) return;
    final now = DateTime.now();
    // 90%: a poll firing on the interval must not lose a cycle to a fetch
    // that ran a moment after it was scheduled.
    if (!force && _lastFetch != null && now.difference(_lastFetch!) < widget.refreshInterval * 0.9) return;
    _lastFetch = now;
    // Another contact signed in: the previous one's messages go.
    final owner = await client.contactKey();
    if (!mounted) return;
    if (owner != _owner) {
      _clearMessages();
      _owner = owner;
    }
    final List<InAppMessage> messages;
    try {
      messages = await Sequenzy.fetchMessages(includeHtml: widget.showHtmlMessages);
    } catch (_) {
      return;
    }
    if (!mounted || await client.contactKey() != owner) return;
    for (final message in messages) {
      if (message.isCard || _shown.contains(message.id) || _current?.id == message.id) continue;
      if (message.resolvedFormat == 'html' && (!widget.showHtmlMessages || message.html == null)) continue;
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
      _htmlLoaded = false;
      setState(() => _current = next);
      // Custom HTML reports displayed once its document has loaded.
      if (next.resolvedFormat != 'html') unawaited(Sequenzy.report(InAppEventType.displayed, next));
      return;
    }
  }

  void _close() {
    setState(() => _current = null);
    _showNext();
  }

  void _openUrl(String url, InAppMessage message) {
    if (widget.onOpenUrl?.call(url, message) != true) unawaited(Sequenzy.urlOpener(url));
  }

  /// Runs [action] only while the contact [message] was fetched for is still
  /// signed in; otherwise closes it, unreported.
  void _forOwner(InAppMessage message, String? owner, void Function() action) {
    unawaited(() async {
      if (await Sequenzy.client?.contactKey() != owner) {
        if (mounted && _current?.id == message.id) _close();
        return;
      }
      if (mounted) action();
    }());
  }

  Widget _htmlView(InAppMessage message) {
    final owner = _owner;
    return InAppHtmlMessageView(
        key: ValueKey(message.id),
        message: message,
        backRequests: _back,
        onLoaded: () {
          _htmlLoaded = true;
          _forOwner(message, owner, () => unawaited(Sequenzy.report(InAppEventType.displayed, message)));
        },
        onBridge: (call) => _forOwner(message, owner, () {
          switch (call) {
            case InAppHtmlLogClick(:final buttonId):
              unawaited(Sequenzy.report(InAppEventType.clicked, message, buttonId: buttonId));
            case InAppHtmlTrack(:final name, :final properties):
              unawaited(Sequenzy.track(name, properties));
            case InAppHtmlSetAttributes(:final attributes):
              unawaited(Sequenzy.setProfile(ProfileUpdate(attributes: attributes)));
            case InAppHtmlSetName(:final firstName, :final lastName):
              unawaited(Sequenzy.setProfile(ProfileUpdate(firstName: firstName, lastName: lastName)));
            default:
              break;
          }
        }),
        onFinish: (outcome) => _forOwner(message, owner, () {
          switch (outcome) {
            case InAppHtmlDismissed():
              unawaited(Sequenzy.report(InAppEventType.dismissed, message));
            case InAppHtmlOpened(:final url, :final buttonId):
              unawaited(Sequenzy.report(InAppEventType.clicked, message, buttonId: buttonId));
              _openUrl(url, message);
            case InAppHtmlFailed():
              break;
          }
          _close();
        }),
      );
  }

  @override
  Widget build(BuildContext context) {
    final message = _current;
    return Stack(children: [
      widget.child,
      if (message != null && message.resolvedFormat == 'html') Positioned.fill(child: _htmlView(message)),
      if (message != null && message.resolvedFormat != 'html')
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
              // A banner tap (null) acts like its primary button
              final target = button ?? message.buttons.where((candidate) => candidate.acts).firstOrNull;
              if (target != null && target.requestsPushPermission) {
                unawaited(Sequenzy.handleButtonPress(target, message));
                _close();
                return;
              }
              unawaited(Sequenzy.report(InAppEventType.clicked, message));
              final url = target?.url ??
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
