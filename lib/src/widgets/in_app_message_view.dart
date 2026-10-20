import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../models.dart';
import 'colors.dart';
import 'design.dart';
import 'parts.dart';

/// Draws one in-app message to mobile-sdks/DESIGN.md. Lay it out over the
/// whole app (a [Stack] above your routes); [SequenzyInAppHost] does.
class InAppMessageView extends StatelessWidget {
  const InAppMessageView({
    super.key,
    required this.message,
    required this.onDismiss,
    required this.onPress,
    this.backRequests,
  });

  final InAppMessage message;

  /// Fires on Android back. A modal or fullscreen message then closes with
  /// its exit animation, exactly like the close button.
  final Listenable? backRequests;

  /// Closed with the X, a dismiss button, a swipe or a tap outside a modal.
  final VoidCallback onDismiss;

  /// A link button, or the banner itself (null button).
  final void Function(InAppButton? button) onPress;

  @override
  Widget build(BuildContext context) {
    return withTextScaleCap(
      context,
      Material(
        type: MaterialType.transparency,
        child: switch (message.resolvedFormat) {
          'banner' => _Banner(view: this),
          'fullscreen' => _Fullscreen(view: this),
          _ => _Modal(view: this),
        },
      ),
    );
  }
}

/// (damping ratio, response in seconds) as a spring for a mass of 1.
SpringDescription _spring(double ratio, double response) {
  final stiffness = math.pow(2 * math.pi / response, 2).toDouble();
  return SpringDescription(mass: 1, stiffness: stiffness, damping: 2 * ratio * math.sqrt(stiffness));
}

final _sheetSpring = _spring(0.86, 0.42);
final _dialogSpring = _spring(0.86, 0.32);
final _bannerSpring = _spring(0.86, 0.38);

/// Presence animation shared by every format: 0 hidden, 1 shown. Exits run
/// once, then call back.
mixin _Presence<T extends StatefulWidget> on State<T>, TickerProviderStateMixin<T> {
  late final AnimationController presence = AnimationController(vsync: this, upperBound: 1.2);
  bool _leaving = false;

  bool get reduceMotion => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  void enter(SpringDescription spring) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (reduceMotion) {
        presence.animateTo(1, duration: const Duration(milliseconds: 180));
      } else {
        presence.animateWith(SpringSimulation(spring, 0, 1, 0));
      }
    });
  }

  void exit(VoidCallback after, {Duration duration = const Duration(milliseconds: 200)}) {
    if (_leaving) return;
    _leaving = true;
    presence
        .animateTo(0, duration: reduceMotion ? const Duration(milliseconds: 180) : duration, curve: Curves.easeInCubic)
        .whenCompleteOrCancel(after);
  }

  void Function(InAppButton) buttonHandler(InAppMessageView view) =>
      (button) => exit(() => button.opensUrl ? view.onPress(button) : view.onDismiss());

  @override
  void dispose() {
    presence.dispose();
    super.dispose();
  }
}

class _Modal extends StatefulWidget {
  const _Modal({required this.view});

  final InAppMessageView view;

  @override
  State<_Modal> createState() => _ModalState();
}

class _ModalState extends State<_Modal> with TickerProviderStateMixin, _Presence {
  bool _imageFailed = false;
  double _drag = 0;
  double _sheetHeight = 0;
  late final AnimationController _dragBack = AnimationController(vsync: this)
    ..addListener(() => setState(() => _drag = _dragBack.value));

  InAppMessage get message => widget.view.message;

  @override
  void initState() {
    super.initState();
    enter(message.position == 'center' ? _dialogSpring : _sheetSpring);
    widget.view.backRequests?.addListener(_onBack);
  }

  @override
  void dispose() {
    widget.view.backRequests?.removeListener(_onBack);
    _dragBack.dispose();
    super.dispose();
  }

  void _onBack() => _dismiss(!isDialog(message, MediaQuery.sizeOf(context).width));

  void _dismiss(bool sheet) => exit(widget.view.onDismiss, duration: Duration(milliseconds: sheet ? 220 : 160));

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = media.size.width;
    final dialog = isDialog(message, width);
    final sheet = !dialog;
    final placement = _imageFailed ? null : imagePlacementOf(message);
    final onImage = placement == 'background';
    final style = message.style;
    final palette = onImage ? Palette.image(style) : Palette.surface(style);
    final closePalette = placement != null ? Palette.image(style) : Palette.surface(style);
    final type = InAppType(style.primaryFont);
    final panelWidth = dialog ? math.min(width - 40, 360.0) : width;
    final radius = Radius.circular(style.cornerRadius);

    final content = Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        placement == 'top' ? 20 : 28,
        24,
        sheet ? math.max(16 + media.viewPadding.bottom, 24) : 24,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InAppTextBlock(message: message, palette: palette, type: type, center: dialog, bodyMaxLines: 10),
        InAppButtonStack(message: message, palette: palette, type: type, onButton: buttonHandler(widget.view)),
      ]),
    );

    Widget body;
    if (onImage) {
      body = ConstrainedBox(
        constraints: BoxConstraints(minHeight: sheet ? 460 : panelWidth * 1.25),
        child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.end, children: [content]),
      );
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (placement == 'top')
          SizedBox(
            height: math.min(panelWidth * 9 / 16, 260),
            child: InAppNetworkImage(
                url: message.imageUrl!, style: style, onError: () => setState(() => _imageFailed = true)),
          ),
        content,
      ]);
    }

    final panel = Container(
      key: Key(sheet ? 'sequenzy-sheet' : 'sequenzy-modal'),
      width: panelWidth,
      constraints: BoxConstraints(
        maxHeight: sheet
            ? media.size.height - media.viewPadding.top - 24
            : media.size.height - media.viewPadding.vertical - 48,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: sheet ? BorderRadius.vertical(top: radius) : BorderRadius.all(radius),
        boxShadow: dialog ? const [BoxShadow(color: Color(0x2E000000), blurRadius: 48, offset: Offset(0, 24))] : null,
      ),
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        child: Stack(children: [
          if (onImage) ...[
            Positioned.fill(
              child: InAppNetworkImage(
                  url: message.imageUrl!, style: style, onError: () => setState(() => _imageFailed = true)),
            ),
            const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: scrimGradient))),
          ],
          // Long copy at large text sizes scrolls; the close button stays put.
          SingleChildScrollView(
              key: const Key('sequenzy-modal-scroll'), physics: const ClampingScrollPhysics(), child: body),
          if (sheet)
            Positioned(
              top: 6,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: placement != null ? const Color(0xB3FFFFFF) : style.text.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2.5),
                  ),
                ),
              ),
            ),
          // The close button carries 8 of touch padding around its circle.
          Positioned(
              top: 6, right: 6, child: SequenzyCloseButton(palette: closePalette, onPressed: () => _dismiss(sheet))),
        ]),
      ),
    );

    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          key: const Key('sequenzy-backdrop'),
          onTap: () => _dismiss(sheet),
          child: AnimatedBuilder(
            animation: presence,
            builder: (context, _) => ColoredBox(
              color: Colors.black.withValues(alpha: (onImage ? 0.5 : 0.4) * presence.value.clamp(0, 1)),
            ),
          ),
        ),
      ),
      if (dialog)
        Center(
          child: AnimatedBuilder(
            animation: presence,
            builder: (context, child) => Opacity(
              opacity: presence.value.clamp(0, 1),
              child: Transform.scale(scale: reduceMotion ? 1 : 0.94 + 0.06 * presence.value, child: child),
            ),
            child: panel,
          ),
        )
      else
        Align(
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onVerticalDragUpdate: (details) {
              _dragBack.stop();
              setState(() {
                final next = _drag + details.delta.dy;
                // Upward drags resist at a third of the distance.
                _drag = next > 0 ? next : _drag + details.delta.dy / 3;
              });
            },
            onVerticalDragEnd: (details) {
              final velocity = details.velocity.pixelsPerSecond.dy;
              if (_drag > _sheetHeight * 0.3 || velocity > 1000) {
                _dismiss(true);
              } else {
                _dragBack.value = _drag;
                _dragBack.animateWith(SpringSimulation(_sheetSpring, _drag, 0, velocity));
              }
            },
            child: AnimatedBuilder(
              animation: presence,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, _drag),
                child: reduceMotion
                    ? Opacity(opacity: presence.value.clamp(0, 1), child: child)
                    : FractionalTranslation(translation: Offset(0, 1 - presence.value.clamp(0, 1)), child: child),
              ),
              child: LayoutBuilder(builder: (context, constraints) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box != null && box.hasSize) _sheetHeight = box.size.height;
                });
                return panel;
              }),
            ),
          ),
        ),
    ]);
  }
}

class _Fullscreen extends StatefulWidget {
  const _Fullscreen({required this.view});

  final InAppMessageView view;

  @override
  State<_Fullscreen> createState() => _FullscreenState();
}

class _FullscreenState extends State<_Fullscreen> with TickerProviderStateMixin, _Presence {
  bool _imageFailed = false;

  InAppMessage get message => widget.view.message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        presence.animateTo(1, duration: Duration(milliseconds: reduceMotion ? 180 : 280), curve: Curves.easeOutCubic);
      }
    });
    widget.view.backRequests?.addListener(_onBack);
  }

  @override
  void dispose() {
    widget.view.backRequests?.removeListener(_onBack);
    super.dispose();
  }

  void _onBack() => exit(widget.view.onDismiss);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final style = message.style;
    final placement = _imageFailed ? null : imagePlacementOf(message);
    final onImage = placement == 'background';
    final palette = onImage ? Palette.image(style) : Palette.surface(style);
    final type = InAppType(style.primaryFont);
    void imageFailed() => setState(() => _imageFailed = true);

    final column = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (placement == 'top')
        SizedBox(
          height: media.size.height * 0.48,
          child: InAppNetworkImage(url: message.imageUrl!, style: style, onError: imageFailed),
        ),
      Expanded(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              24, placement == 'top' ? 28 : media.viewPadding.top + 56, 24, 16 + media.viewPadding.bottom),
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (placement != 'top') const Spacer(flex: 10),
                    InAppTextBlock(message: message, palette: palette, type: type, fullscreen: true),
                    if (!onImage) Spacer(flex: placement == 'top' ? 10 : 14),
                    InAppButtonStack(
                        message: message, palette: palette, type: type, onButton: buttonHandler(widget.view)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    ]);

    return AnimatedBuilder(
      animation: presence,
      builder: (context, child) => Opacity(
        opacity: presence.value.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, reduceMotion ? 0 : 24 * (1 - presence.value.clamp(0, 1))),
          child: child,
        ),
      ),
      child: Container(
        key: const Key('sequenzy-fullscreen'),
        color: style.background,
        child: Stack(children: [
          if (onImage) ...[
            Positioned.fill(child: InAppNetworkImage(url: message.imageUrl!, style: style, onError: imageFailed)),
            const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: scrimGradient))),
          ],
          Positioned.fill(child: column),
          Positioned(
            top: media.viewPadding.top + 4,
            right: 8,
            child: SequenzyCloseButton(
              palette: placement != null ? Palette.image(style) : palette,
              size: 32,
              onPressed: () => exit(widget.view.onDismiss),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Banner extends StatefulWidget {
  const _Banner({required this.view});

  final InAppMessageView view;

  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> with TickerProviderStateMixin, _Presence {
  bool _imageFailed = false;
  double _drag = 0;
  double _height = 80;

  InAppMessage get message => widget.view.message;
  bool get top => message.position == 'top';

  @override
  void initState() {
    super.initState();
    enter(_bannerSpring);
  }

  void _close() => exit(widget.view.onDismiss, duration: const Duration(milliseconds: 180));

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final style = message.style;
    final palette = Palette.surface(style);
    final type = InAppType(style.primaryFont);
    final (:primary, secondary: _) = splitButtons(message.buttons);
    final link = primary != null && primary.opensUrl ? primary : null;
    final direction = top ? -1.0 : 1.0;
    final edge = top ? 8 + media.viewPadding.top : 12 + media.viewPadding.bottom;
    final hasTitle = message.title.isNotEmpty;

    final banner = Container(
      key: const Key('sequenzy-banner'),
      constraints: const BoxConstraints(maxWidth: 480),
      padding: const EdgeInsets.fromLTRB(14, 12, 0, 12),
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(math.min(style.cornerRadius, 24)),
        border: Border.all(color: style.text.withValues(alpha: 0.06), width: 0.5),
        boxShadow: const [BoxShadow(color: Color(0x29000000), blurRadius: 24, offset: Offset(0, 8))],
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          // The close button is a sibling of the tappable area, so screen
          // readers see two controls instead of one with a nested button.
          child: InAppPressable(
            pressedOpacity: link != null ? 0.85 : 1,
            onTap: () {
              if (link != null) exit(() => widget.view.onPress(null), duration: const Duration(milliseconds: 180));
            },
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (message.imageUrl != null && !_imageFailed)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: InAppNetworkImage(
                          url: message.imageUrl!, style: style, onError: () => setState(() => _imageFailed = true)),
                    ),
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child:
                      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    if (hasTitle) Text(message.title, style: type.bannerTitle(palette.text)),
                    if (message.body.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: hasTitle ? 2 : 0),
                        child: Text(
                          message.body,
                          maxLines: hasTitle ? 2 : 3,
                          overflow: TextOverflow.ellipsis,
                          style: hasTitle ? type.bannerBody(palette.muted) : type.bannerBodyAlone(palette.text),
                        ),
                      ),
                    if (link != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(link.label,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: type.bannerLink(palette.eyebrow)),
                      ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: CompactCloseButton(palette: palette, size: 28, onPressed: _close),
        ),
      ]),
    );

    return Stack(children: [
      Positioned(
        left: 12,
        right: 12,
        top: top ? edge : null,
        bottom: top ? null : edge,
        child: Center(
          child: GestureDetector(
            onVerticalDragUpdate: (details) => setState(() {
              final towardEdge = details.delta.dy * direction > 0;
              _drag += towardEdge ? details.delta.dy : details.delta.dy / 3;
            }),
            onVerticalDragEnd: (details) {
              final velocity = details.velocity.pixelsPerSecond.dy * direction;
              if (_drag * direction > _height * 0.4 || velocity > 800) {
                _close();
              } else {
                setState(() => _drag = 0);
              }
            },
            child: AnimatedBuilder(
              animation: presence,
              builder: (context, child) {
                final shown = presence.value.clamp(0.0, 1.2);
                return Transform.translate(
                  offset: Offset(0, _drag + (reduceMotion ? 0 : direction * (1 - shown) * (_height + edge + 16))),
                  child: Opacity(opacity: reduceMotion ? presence.value.clamp(0, 1) : 1, child: child),
                );
              },
              child: LayoutBuilder(builder: (context, constraints) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box != null && box.hasSize) _height = box.size.height;
                });
                return banner;
              }),
            ),
          ),
        ),
      ),
    ]);
  }
}
