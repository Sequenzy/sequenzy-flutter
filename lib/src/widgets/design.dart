// Drawing rules from mobile-sdks/DESIGN.md, shared with every other
// renderer (iOS, Android, React Native, the dashboard preview).
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../models.dart';
import 'colors.dart';

/// Text scales with the system size, up to this much.
const double maxTextScale = 1.4;

double _channel(double value) => value <= 0.03928 ? value / 12.92 : math.pow((value + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color color) => 0.2126 * _channel(color.r) + 0.7152 * _channel(color.g) + 0.0722 * _channel(color.b);

/// WCAG contrast ratio, 1 to 21.
double contrastRatio(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

class Palette {
  const Palette({
    required this.text,
    required this.muted,
    required this.eyebrow,
    required this.primaryBackground,
    required this.primaryText,
    required this.secondaryLink,
    required this.secondaryDismiss,
    required this.closeFill,
    required this.closeStroke,
  });

  final Color text;
  final Color muted;
  final Color eyebrow;
  final Color primaryBackground;
  final Color primaryText;
  final Color secondaryLink;
  final Color secondaryDismiss;
  final Color closeFill;
  final Color closeStroke;

  factory Palette.surface(InAppStyle style) => Palette(
        text: style.text,
        muted: style.mutedText,
        eyebrow: contrastRatio(style.button, style.background) >= 3 ? style.button : style.mutedText,
        primaryBackground: style.button,
        primaryText: style.buttonText,
        secondaryLink: style.text,
        secondaryDismiss: style.mutedText,
        closeFill: style.text.withValues(alpha: 0.06),
        closeStroke: style.text.withValues(alpha: 0.6),
      );

  /// Over a background image's dark gradient.
  factory Palette.image(InAppStyle style) {
    final keepsAccent = contrastRatio(style.button, const Color(0xFF1F1F1F)) >= 2;
    return Palette(
      text: const Color(0xFFFFFFFF),
      muted: const Color(0xD1FFFFFF),
      eyebrow: const Color(0xE6FFFFFF),
      primaryBackground: keepsAccent ? style.button : const Color(0xFFFFFFFF),
      primaryText: keepsAccent ? style.buttonText : const Color(0xFF111111),
      secondaryLink: const Color(0xFFFFFFFF),
      secondaryDismiss: const Color(0xD1FFFFFF),
      closeFill: const Color(0x52000000),
      closeStroke: const Color(0xFFFFFFFF),
    );
  }
}

/// The dark gradient over a background image.
const scrimGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0x00000000), Color(0x8C000000), Color(0xD1000000)],
  stops: [0, 0.55, 1],
);

/// The primary button (first link, or first button) and the other one.
({InAppButton? primary, InAppButton? secondary}) splitButtons(List<InAppButton> buttons) {
  final index = buttons.indexWhere((button) => button.opensUrl);
  final primaryIndex = index == -1 ? 0 : index;
  InAppButton? secondary;
  for (var i = 0; i < buttons.length; i++) {
    if (i != primaryIndex) {
      secondary = buttons[i];
      break;
    }
  }
  return (primary: buttons.isEmpty ? null : buttons[primaryIndex], secondary: secondary);
}

/// "background" only when there is an image to put behind the text.
String? imagePlacementOf(InAppMessage message) {
  if (message.imageUrl == null) return null;
  return message.imagePlacement == 'background' ? 'background' : 'top';
}

/// Sheets become dialogs on screens 600 or wider.
bool isDialog(InAppMessage message, double width) => message.position == 'center' || width >= 600;

/// Type ramp from the spec; [font] is the app-mapped brand font, if any.
class InAppType {
  const InAppType(this.font);

  final String? font;

  TextStyle _style(double size, double lineHeight, FontWeight weight, Color color, {double letterSpacing = 0}) =>
      TextStyle(
        fontFamily: font,
        fontSize: size,
        height: lineHeight / size,
        fontWeight: weight,
        letterSpacing: letterSpacing,
        color: color,
      );

  TextStyle eyebrow(Color color) => _style(13, 18, FontWeight.w600, color);
  TextStyle title(Color color, {bool fullscreen = false}) => fullscreen
      ? _style(30, 36, FontWeight.w700, color, letterSpacing: -0.6)
      : _style(22, 28, FontWeight.w700, color, letterSpacing: -0.4);
  TextStyle body(Color color, {bool fullscreen = false}) =>
      fullscreen ? _style(17, 25, FontWeight.w400, color) : _style(16, 23, FontWeight.w400, color);
  TextStyle button(Color color) => _style(17, 22, FontWeight.w600, color);
  TextStyle bannerTitle(Color color) => _style(15, 20, FontWeight.w600, color);
  TextStyle bannerBody(Color color) => _style(14, 19, FontWeight.w400, color);
  TextStyle bannerBodyAlone(Color color) => _style(15, 20, FontWeight.w500, color);
  TextStyle bannerLink(Color color) => _style(14, 19, FontWeight.w600, color);
  TextStyle cardEyebrow(Color color) => _style(12, 16, FontWeight.w600, color);
  TextStyle cardTitle(Color color) => _style(16, 21, FontWeight.w600, color);
  TextStyle cardBody(Color color) => _style(14, 20, FontWeight.w400, color);
  TextStyle cardLink(Color color) => _style(15, 20, FontWeight.w600, color);
}

/// Caps the system text size at [maxTextScale].
Widget withTextScaleCap(BuildContext context, Widget child) {
  final media = MediaQuery.of(context);
  return MediaQuery(
    data: media.copyWith(textScaler: media.textScaler.clamp(maxScaleFactor: maxTextScale)),
    child: child,
  );
}
