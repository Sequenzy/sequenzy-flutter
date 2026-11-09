import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models.dart';
import 'colors.dart';
import 'design.dart';
import 'parts.dart';

/// A placement item with the banner or hero layout of mobile-sdks/DESIGN.md
/// ("Placement"). Card items are drawn by [InAppCardView].
class PlacementItemView extends StatefulWidget {
  const PlacementItemView({super.key, required this.item, required this.onButton});

  final InAppMessage item;

  /// Runs a button's action.
  final void Function(InAppButton button) onButton;

  @override
  State<PlacementItemView> createState() => _PlacementItemViewState();
}

class _PlacementItemViewState extends State<PlacementItemView> {
  bool _imageFailed = false;

  @override
  void didUpdateWidget(PlacementItemView old) {
    super.didUpdateWidget(old);
    if (old.item.id != widget.item.id) _imageFailed = false;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final style = item.style;
    final hero = item.resolvedLayout == 'hero';
    final image = _imageFailed ? null : item.imageUrl;
    final overImage = hero && image != null;
    final palette = overImage ? Palette.image(style) : Palette.surface(style);
    final type = InAppType(style.primaryFont);
    final eyebrow = item.eyebrow.trim();
    void failed() => setState(() => _imageFailed = true);

    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (eyebrow.isNotEmpty)
        Padding(
          padding: EdgeInsets.only(bottom: hero ? 6 : 4),
          child: Text(eyebrow, style: hero ? type.eyebrow(palette.eyebrow) : type.cardEyebrow(palette.eyebrow)),
        ),
      if (item.title.isNotEmpty) Text(item.title, style: hero ? type.heroTitle(palette.text) : type.cardTitle(palette.text)),
      if (item.body.isNotEmpty)
        Padding(
          padding: EdgeInsets.only(top: item.title.isEmpty ? 0 : (hero ? 6 : 4)),
          child: Text(item.body,
              maxLines: hero ? 3 : 2, overflow: TextOverflow.ellipsis, style: type.cardBody(palette.muted)),
        ),
      _Buttons(item: item, palette: palette, type: type, top: hero ? 14 : 10, onButton: widget.onButton),
    ]);

    final decoration = BoxDecoration(
      color: style.background,
      borderRadius: BorderRadius.circular(style.cornerRadius),
      border: Border.all(color: style.text.withValues(alpha: 0.08), width: 0.5),
      boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
    );

    if (!hero) {
      return withTextScaleCap(
        context,
        Container(
          key: Key('sequenzy-placement-item-${item.id}'),
          clipBehavior: Clip.antiAlias,
          decoration: decoration,
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (image != null)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(math.min(style.cornerRadius, 12)),
                  child: SizedBox(
                      width: 56, height: 56, child: InAppNetworkImage(url: image, style: style, onError: failed)),
                ),
              ),
            Expanded(child: text),
          ]),
        ),
      );
    }

    return withTextScaleCap(
      context,
      LayoutBuilder(
        builder: (context, constraints) => Container(
          key: Key('sequenzy-placement-item-${item.id}'),
          clipBehavior: Clip.antiAlias,
          decoration: decoration,
          child: Stack(children: [
            if (image != null) Positioned.fill(child: InAppNetworkImage(url: image, style: style, onError: failed)),
            if (image != null)
              const Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: scrimGradient))),
            Container(
              constraints: BoxConstraints(minHeight: constraints.maxWidth.isFinite ? constraints.maxWidth / 2 : 0),
              alignment: Alignment.bottomLeft,
              padding: const EdgeInsets.all(20),
              child: text,
            ),
          ]),
        ),
      ),
    );
  }
}

/// A filled primary button, then the other button as a text link.
class _Buttons extends StatelessWidget {
  const _Buttons(
      {required this.item, required this.palette, required this.type, required this.top, required this.onButton});

  final InAppMessage item;
  final Palette palette;
  final InAppType type;
  final double top;
  final void Function(InAppButton button) onButton;

  @override
  Widget build(BuildContext context) {
    final (:primary, :secondary) = splitButtons(item.buttons);
    if (primary == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        InAppPressable(
          onTap: () => onButton(primary),
          child: Container(
            key: const Key('sequenzy-placement-primary'),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.primaryBackground,
              borderRadius: BorderRadius.circular(math.min(item.style.buttonRadius, 18)),
            ),
            child: Text(primary.label, style: type.bannerLink(palette.primaryText)),
          ),
        ),
        if (secondary != null)
          InAppPressable(
            onTap: () => onButton(secondary),
            child: Text(secondary.label, style: type.bannerLink(palette.muted)),
          ),
      ]),
    );
  }
}
