import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../sequenzy.dart';
import 'colors.dart';
import 'design.dart';
import 'parts.dart';

/// A content card drawn to mobile-sdks/DESIGN.md.
class InAppCardView extends StatefulWidget {
  const InAppCardView({super.key, required this.card, this.onDismiss});

  final InAppMessage card;

  /// Handles the dismiss button. Pass [InAppCardsController.dismiss], which
  /// reports the dismissal and drops the card; without it the card reports it.
  final void Function(InAppMessage card)? onDismiss;

  @override
  State<InAppCardView> createState() => _InAppCardViewState();
}

class _InAppCardViewState extends State<InAppCardView> {
  bool _imageFailed = false;

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final style = card.style;
    final palette = Palette.surface(style);
    final type = InAppType(style.primaryFont);
    final (:primary, :secondary) = splitButtons(card.buttons);
    final eyebrow = card.eyebrow.trim();

    void dismiss() {
      final onDismiss = widget.onDismiss;
      if (onDismiss != null) {
        onDismiss(card);
      } else {
        unawaited(Sequenzy.report(InAppEventType.dismissed, card));
      }
    }

    void press(InAppButton button) {
      if (button.opensUrl) {
        unawaited(Sequenzy.handleButtonPress(button, card));
      } else {
        dismiss();
      }
    }

    return withTextScaleCap(
      context,
      Container(
        key: Key('sequenzy-card-${card.id}'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: style.background,
          borderRadius: BorderRadius.circular(style.cornerRadius),
          border: Border.all(color: style.text.withValues(alpha: 0.08), width: 0.5),
          boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          if (card.imageUrl != null && !_imageFailed)
            AspectRatio(
              aspectRatio: 2,
              child: InAppNetworkImage(
                  url: card.imageUrl!, style: style, onError: () => setState(() => _imageFailed = true)),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              if (eyebrow.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(eyebrow, style: type.cardEyebrow(palette.eyebrow)),
                ),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (!card.isRead)
                  Padding(
                    padding: const EdgeInsets.only(top: 6.5, right: 8),
                    child: Semantics(
                      label: 'Unread',
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: style.button, shape: BoxShape.circle),
                      ),
                    ),
                  ),
                Expanded(child: Text(card.title, style: type.cardTitle(palette.text))),
                if (card.pinned) PinGlyph(color: palette.muted),
                CompactCloseButton(palette: palette, size: 24, onPressed: dismiss),
              ]),
              if (card.body.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(card.body,
                      maxLines: 4, overflow: TextOverflow.ellipsis, style: type.cardBody(palette.muted)),
                ),
              if (primary != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(spacing: 20, children: [
                    InAppPressable(
                      onTap: () => press(primary),
                      child: Text(primary.label, style: type.cardLink(palette.eyebrow)),
                    ),
                    if (secondary != null)
                      InAppPressable(
                        onTap: () => press(secondary),
                        child: Text(secondary.label, style: type.cardLink(palette.muted)),
                      ),
                  ]),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The identified contact's content cards, refreshed after identify and reset.
class InAppCardsController extends ChangeNotifier {
  InAppCardsController({this.limit}) {
    _subscription = Sequenzy.identityEvents.listen((event) {
      if (event == SequenzyIdentityEvent.identified) {
        unawaited(refresh());
      } else {
        cards = [];
        notifyListeners();
      }
    });
  }

  final int? limit;
  StreamSubscription<SequenzyIdentityEvent>? _subscription;
  List<InAppMessage> cards = [];
  bool loading = false;
  Object? error;

  Future<void> refresh() async {
    loading = true;
    notifyListeners();
    try {
      cards = await Sequenzy.fetchCards(limit: limit);
      error = null;
    } catch (caught) {
      error = caught;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  final _readReported = <String>{};

  /// Marks a card read, e.g. when it scrolls into view. Safe to call again
  /// with a stale copy of the card: each card is reported once.
  void markRead(InAppMessage card) {
    final current = cards.where((item) => item.id == card.id).firstOrNull ?? card;
    if (current.isRead || !_readReported.add(card.id)) return;
    unawaited(Sequenzy.report(InAppEventType.read, card));
    cards = [
      for (final item in cards)
        item.id == card.id ? item.copyWith(readAt: DateTime.now().toUtc().toIso8601String()) : item,
    ];
    notifyListeners();
  }

  /// Reports a dismissal and removes the card from the list.
  void dismiss(InAppMessage card) {
    unawaited(Sequenzy.report(InAppEventType.dismissed, card));
    cards = cards.where((item) => item.id != card.id).toList();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
