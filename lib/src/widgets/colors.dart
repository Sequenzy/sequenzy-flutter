import 'package:flutter/widgets.dart';

import '../models.dart';

/// Parses `#rrggbb`, falling back to [fallback].
Color hexColor(String hex, Color fallback) {
  final value = hex.trim().replaceFirst('#', '');
  if (value.length != 6) return fallback;
  final parsed = int.tryParse(value, radix: 16);
  return parsed == null ? fallback : Color(0xFF000000 | parsed);
}

extension InAppStyleColors on InAppStyle {
  Color get background => hexColor(backgroundColor, const Color(0xFFFFFFFF));
  Color get text => hexColor(textColor, const Color(0xFF111827));
  Color get mutedText => hexColor(mutedTextColor, const Color(0xFF4B5563));
  Color get button => hexColor(buttonColor, const Color(0xFF111827));
  Color get buttonText => hexColor(buttonTextColor, const Color(0xFFFFFFFF));
  String? get primaryFont => fontFamilies.isEmpty ? null : fontFamilies.first;
}
