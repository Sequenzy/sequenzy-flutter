import 'dart:async';
import 'dart:convert';

/// A call from a custom HTML in-app message to the app, sent by the Sequenzy
/// JS bridge the server injects into every document (`window.sequenzy`, plus
/// Braze's `brazeBridge` / `appboyBridge`). Wire shape (protocol v1):
/// `{ "__sequenzyInApp": 1, "method": ..., "args": {...} }`.
sealed class InAppHtmlBridgeMessage {
  const InAppHtmlBridgeMessage();

  /// Messages larger than this are dropped, as the bridge itself does.
  static const maxMessageBytes = 32 * 1024;

  /// Bridge calls honored per display; the rest are dropped.
  static const maxCallsPerDisplay = 50;

  /// Where custom HTML documents load: a fixed https origin Sequenzy owns, so
  /// the document has a real origin (local storage works for survey scripts)
  /// that is never the app's own web content.
  static const baseUrl = 'https://in-app.sequenzy.com/';

  static final _buttonId = RegExp(r'^[A-Za-z0-9 _-]{1,255}$');
  static final _scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):');
  static const _blockedSchemes = {'http', 'javascript', 'data', 'vbscript', 'file', 'blob', 'about', 'filesystem'};

  /// Braze's logClick id rule: 1-255 letters, numbers, spaces, dashes or underscores.
  static bool isValidButtonId(String id) => _buttonId.hasMatch(id);

  /// https, or an app scheme (myapp://, mailto:, tel:); never script, data,
  /// file or plain-http URLs.
  static bool isAllowedUrl(String url) {
    final match = _scheme.firstMatch(url.trim());
    if (match == null) return false;
    final scheme = match.group(1)!.toLowerCase();
    return scheme == 'https' || !_blockedSchemes.contains(scheme);
  }

  /// Parses one bridge message (a JavaScript channel message); null drops it.
  static InAppHtmlBridgeMessage? parse(String raw) {
    if (utf8.encode(raw).length > maxMessageBytes) return null;
    Object? value;
    try {
      value = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (value is! Map || value['__sequenzyInApp'] != 1) return null;
    final rawArgs = value['args'];
    final args = rawArgs is Map ? rawArgs : const <String, Object?>{};
    String? string(String key, [int max = 255]) {
      final candidate = args[key];
      if (candidate is! String || candidate.isEmpty) return null;
      return candidate.length > max ? candidate.substring(0, max) : candidate;
    }

    String? buttonId() {
      final id = string('buttonId');
      return id != null && isValidButtonId(id) ? id : null;
    }

    Map<String, Object?>? object(String key) {
      final candidate = args[key];
      return candidate is Map ? candidate.map((key, value) => MapEntry('$key', value as Object?)) : null;
    }

    switch (value['method']) {
      case 'close':
        return const InAppHtmlClose();
      case 'openUrl':
        final url = string('url', 2048);
        return url == null ? null : InAppHtmlOpenUrl(url, external: args['external'] == true, buttonId: buttonId());
      case 'logClick':
        return InAppHtmlLogClick(buttonId());
      case 'track':
        final name = string('name');
        return name == null ? null : InAppHtmlTrack(name, object('properties') ?? const {});
      case 'setAttributes':
        final attributes = object('attributes');
        return attributes == null ? null : InAppHtmlSetAttributes(attributes);
      case 'setName':
        final first = string('firstName');
        final last = string('lastName');
        return first == null && last == null ? null : InAppHtmlSetName(firstName: first, lastName: last);
      default:
        return null;
    }
  }
}

/// Close the message (reported as dismissed).
class InAppHtmlClose extends InAppHtmlBridgeMessage {
  const InAppHtmlClose();
}

/// Open a link through the app (reported as a click), then close.
class InAppHtmlOpenUrl extends InAppHtmlBridgeMessage {
  const InAppHtmlOpenUrl(this.url, {required this.external, this.buttonId});
  final String url;
  final bool external;
  final String? buttonId;
}

/// Report a click without closing (Braze `logClick`).
class InAppHtmlLogClick extends InAppHtmlBridgeMessage {
  const InAppHtmlLogClick(this.buttonId);
  final String? buttonId;
}

/// A custom event on the contact (`Sequenzy.track`).
class InAppHtmlTrack extends InAppHtmlBridgeMessage {
  const InAppHtmlTrack(this.name, this.properties);
  final String name;
  final Map<String, Object?> properties;
}

/// Custom attributes on the contact (`Sequenzy.setProfile`).
class InAppHtmlSetAttributes extends InAppHtmlBridgeMessage {
  const InAppHtmlSetAttributes(this.attributes);
  final Map<String, Object?> attributes;
}

/// The contact's name (`Sequenzy.setProfile`).
class InAppHtmlSetName extends InAppHtmlBridgeMessage {
  const InAppHtmlSetName({this.firstName, this.lastName});
  final String? firstName;
  final String? lastName;
}

/// How a custom HTML message ended.
sealed class InAppHtmlOutcome {
  const InAppHtmlOutcome();
}

/// Closed by the document, the close button or Android back.
class InAppHtmlDismissed extends InAppHtmlOutcome {
  const InAppHtmlDismissed();
}

/// The document asked to open [url]; report the click with [buttonId].
class InAppHtmlOpened extends InAppHtmlOutcome {
  const InAppHtmlOpened(this.url, this.buttonId);
  final String url;
  final String? buttonId;
}

/// Never finished loading; not reported, so it shows again later.
class InAppHtmlFailed extends InAppHtmlOutcome {
  const InAppHtmlFailed();
}

/// The state of one displayed custom HTML message, independent of the WebView
/// plugin: load and timeout, the bridge budget, which navigations the WebView
/// may follow, and how the message ends.
class InAppHtmlSession {
  InAppHtmlSession({
    required this.onLoaded,
    required this.onBridge,
    required this.onFinish,
    Duration loadTimeout = const Duration(seconds: 10),
  }) {
    _timeout = Timer(loadTimeout, () {
      if (!loaded) finish(const InAppHtmlFailed());
    });
  }

  /// The document loaded and is visible: report it displayed.
  final void Function() onLoaded;

  /// A bridge call the app handles (click, event, attributes, name).
  final void Function(InAppHtmlBridgeMessage call) onBridge;
  final void Function(InAppHtmlOutcome outcome) onFinish;

  late final Timer _timeout;
  bool loaded = false;
  bool finished = false;
  int _calls = 0;

  void pageFinished() {
    if (loaded || finished) return;
    loaded = true;
    _timeout.cancel();
    onLoaded();
  }

  void mainFrameFailed() {
    if (!loaded) finish(const InAppHtmlFailed());
  }

  /// Whether the WebView may follow a navigation. The document itself and
  /// embedded frames load; other main-frame navigations open through the app.
  bool allowNavigation(String url, {required bool isMainFrame}) {
    final withoutFragment = url.split('#').first;
    if (!isMainFrame || withoutFragment == InAppHtmlBridgeMessage.baseUrl || url.startsWith('about:')) return true;
    _open(url, null);
    return false;
  }

  void receive(String raw) {
    if (finished) return;
    final call = InAppHtmlBridgeMessage.parse(raw);
    if (call == null) return;
    _calls += 1;
    if (_calls > InAppHtmlBridgeMessage.maxCallsPerDisplay) return;
    switch (call) {
      case InAppHtmlClose():
        finish(const InAppHtmlDismissed());
      case InAppHtmlOpenUrl(:final url, :final buttonId):
        _open(url, buttonId);
      default:
        onBridge(call);
    }
  }

  void _open(String url, String? buttonId) {
    if (!InAppHtmlBridgeMessage.isAllowedUrl(url)) return;
    finish(InAppHtmlOpened(url, buttonId));
  }

  void finish(InAppHtmlOutcome outcome) {
    if (finished) return;
    finished = true;
    _timeout.cancel();
    onFinish(outcome);
  }

  void dispose() => _timeout.cancel();
}
