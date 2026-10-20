import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import 'colors.dart';
import 'design.dart';

/// A 12 × 12 X from two round-capped strokes, on a circle.
class SequenzyCloseButton extends StatelessWidget {
  const SequenzyCloseButton({super.key, required this.palette, required this.onPressed, this.size = 30});

  final Palette palette;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Close',
      excludeSemantics: true,
      child: GestureDetector(
        key: const Key('sequenzy-close'),
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Padding(
          // Enlarges the touch target without moving the circle.
          padding: const EdgeInsets.all(8),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: palette.closeFill, shape: BoxShape.circle),
            child: CustomPaint(painter: _CrossPainter(palette.closeStroke)),
          ),
        ),
      ),
    );
  }
}

class _CrossPainter extends CustomPainter {
  _CrossPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final center = size.center(Offset.zero);
    const half = 6.0;
    canvas.drawLine(center.translate(-half, -half), center.translate(half, half), paint);
    canvas.drawLine(center.translate(half, -half), center.translate(-half, half), paint);
  }

  @override
  bool shouldRepaint(_CrossPainter oldDelegate) => oldDelegate.color != color;
}

/// Lays out a close button at its circle size; the touch padding overflows
/// so it never makes a row taller.
class CompactCloseButton extends StatelessWidget {
  const CompactCloseButton({super.key, required this.palette, required this.onPressed, required this.size});

  final Palette palette;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: OverflowBox(
          maxWidth: size + 16,
          maxHeight: size + 16,
          child: SequenzyCloseButton(palette: palette, onPressed: onPressed, size: size),
        ),
      );
}

/// A small tilted pin for pinned cards.
class PinGlyph extends StatelessWidget {
  const PinGlyph({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Pinned',
        child: SizedBox(
          width: 24,
          height: 24,
          child: Center(
            child: Transform.rotate(
              angle: 35 * math.pi / 180,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                Container(width: 1.5, height: 7, color: color),
              ]),
            ),
          ),
        ),
      );
}

/// Eyebrow, title and body.
class InAppTextBlock extends StatelessWidget {
  const InAppTextBlock({
    super.key,
    required this.message,
    required this.palette,
    required this.type,
    this.fullscreen = false,
    this.center = false,
    this.bodyMaxLines,
  });

  final InAppMessage message;
  final Palette palette;
  final InAppType type;
  final bool fullscreen;
  final bool center;
  final int? bodyMaxLines;

  @override
  Widget build(BuildContext context) {
    final align = center ? TextAlign.center : TextAlign.left;
    // Centered headings keep clear of the close button in the corner.
    final inset = EdgeInsets.symmetric(horizontal: center ? 20 : 0);
    final eyebrow = message.eyebrow.trim();
    return Column(
      crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (eyebrow.isNotEmpty)
          Padding(
            padding: inset.copyWith(bottom: 6),
            child: Text(eyebrow, textAlign: align, style: type.eyebrow(palette.eyebrow)),
          ),
        if (message.title.isNotEmpty)
          Padding(
            padding: inset,
            child: Semantics(
              header: true,
              child: Text(message.title, textAlign: align, style: type.title(palette.text, fullscreen: fullscreen)),
            ),
          ),
        if (message.body.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: message.title.isNotEmpty ? 8 : 0),
            child: Text(
              message.body,
              textAlign: align,
              maxLines: bodyMaxLines,
              overflow: bodyMaxLines == null ? null : TextOverflow.ellipsis,
              style: type.body(palette.muted, fullscreen: fullscreen),
            ),
          ),
      ],
    );
  }
}

/// The primary filled button, the other as plain text below it.
class InAppButtonStack extends StatelessWidget {
  const InAppButtonStack({
    super.key,
    required this.message,
    required this.palette,
    required this.type,
    required this.onButton,
  });

  final InAppMessage message;
  final Palette palette;
  final InAppType type;
  final void Function(InAppButton button) onButton;

  @override
  Widget build(BuildContext context) {
    final (:primary, :secondary) = splitButtons(message.buttons);
    if (primary == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InAppPressable(
          onTap: () => onButton(primary),
          pressedOpacity: 0.85,
          child: Container(
            height: 52,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: palette.primaryBackground,
              borderRadius: BorderRadius.circular(math.min(message.style.buttonRadius, 26)),
            ),
            child: Text(primary.label,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: type.button(palette.primaryText)),
          ),
        ),
        if (secondary != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InAppPressable(
              onTap: () => onButton(secondary),
              pressedOpacity: 0.6,
              child: Container(
                height: 48,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  secondary.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.button(secondary.opensUrl ? palette.secondaryLink : palette.secondaryDismiss),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Dims while pressed; announced as a button.
class InAppPressable extends StatefulWidget {
  const InAppPressable({super.key, required this.onTap, required this.child, this.pressedOpacity = 0.6});

  final VoidCallback onTap;
  final Widget child;
  final double pressedOpacity;

  @override
  State<InAppPressable> createState() => _PressableState();
}

class _PressableState extends State<InAppPressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 90),
            opacity: _pressed ? widget.pressedOpacity : 1,
            child: widget.child,
          ),
        ),
      );
}

/// A network image on a faint placeholder that reports a failed load once.
class InAppNetworkImage extends StatelessWidget {
  const InAppNetworkImage({super.key, required this.url, required this.style, required this.onError});

  final String url;
  final InAppStyle style;
  final VoidCallback onError;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: style.text.withValues(alpha: 0.06),
        child: Image.network(
          url,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (context, error, stack) {
            // The image may be gone by the next frame (message closed).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) onError();
            });
            return const SizedBox.shrink();
          },
        ),
      );
}
