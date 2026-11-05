import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../in_app_html.dart';
import '../models.dart';

/// Shows a custom HTML in-app message over the whole screen in a transparent
/// WebView. The document arrives with the Sequenzy JS bridge already in it;
/// the bridge reaches the app through the `SequenzyFlutter` JavaScript
/// channel.
///
/// The document loads at [InAppHtmlBridgeMessage.baseUrl], never the app's
/// own origin; main-frame navigations away from it are cancelled and go
/// through the app's URL handler. Until it has loaded the view ignores
/// touches, so a slow document never blocks the app.
class InAppHtmlMessageView extends StatefulWidget {
  const InAppHtmlMessageView({
    super.key,
    required this.message,
    required this.onLoaded,
    required this.onBridge,
    required this.onFinish,
    this.backRequests,
  });

  final InAppMessage message;

  /// The document loaded and is visible: report it displayed.
  final VoidCallback onLoaded;

  /// A bridge call the app handles (click, event, attributes, name).
  final void Function(InAppHtmlBridgeMessage call) onBridge;
  final void Function(InAppHtmlOutcome outcome) onFinish;

  /// Ticks when Android back should close the message.
  final ValueListenable<int>? backRequests;

  @override
  State<InAppHtmlMessageView> createState() => _InAppHtmlMessageViewState();
}

class _InAppHtmlMessageViewState extends State<InAppHtmlMessageView> {
  late final InAppHtmlSession _session;
  late final WebViewController _controller;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _session = InAppHtmlSession(
      onLoaded: () {
        if (mounted) setState(() => _loaded = true);
        widget.onLoaded();
      },
      onBridge: (call) => widget.onBridge(call),
      onFinish: (outcome) => widget.onFinish(outcome),
    );
    widget.backRequests?.addListener(_onBack);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel('SequenzyFlutter', onMessageReceived: (message) => _session.receive(message.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) => _session.allowNavigation(request.url, isMainFrame: request.isMainFrame)
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
        onPageFinished: (_) => _session.pageFinished(),
        onWebResourceError: (error) {
          if (error.isForMainFrame ?? true) _session.mainFrameFailed();
        },
      ))
      ..loadHtmlString(widget.message.html ?? '', baseUrl: InAppHtmlBridgeMessage.baseUrl);
  }

  void _onBack() {
    if (_session.loaded) _session.finish(const InAppHtmlDismissed());
  }

  @override
  void dispose() {
    widget.backRequests?.removeListener(_onBack);
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.maybePaddingOf(context)?.top ?? 0;
    return IgnorePointer(
      ignoring: !_loaded,
      child: Semantics(
        label: widget.message.title.isEmpty ? 'Message' : widget.message.title,
        child: Stack(children: [
          Positioned.fill(
            child: Opacity(opacity: _loaded ? 1 : 0, child: WebViewWidget(controller: _controller)),
          ),
          if (_loaded && widget.message.showCloseButton)
            Positioned(
              top: top + 12,
              right: 12,
              child: Semantics(
                button: true,
                label: 'Close',
                child: GestureDetector(
                  onTap: () => _session.finish(const InAppHtmlDismissed()),
                  child: Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: Color(0x8C000000), shape: BoxShape.circle),
                    child: const Text('×', style: TextStyle(color: Color(0xFFFFFFFF), fontSize: 24, height: 1)),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
