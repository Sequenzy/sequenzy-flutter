/// An item in the contact's in-app feed: a message shown over the app, or a
/// content card. Mirrors `InAppMessageView` on the server.
class InAppMessage {
  InAppMessage({
    required this.id,
    required this.kind,
    required this.format,
    required this.position,
    this.eyebrow = '',
    required this.title,
    required this.body,
    required this.imageUrl,
    this.imagePlacement,
    required this.buttons,
    required this.data,
    required this.style,
    required this.pinned,
    required this.createdAt,
    required this.expiresAt,
    required this.displayedAt,
    required this.readAt,
    required this.dismissedAt,
  });

  final String id;

  /// `message` or `card`.
  final String kind;

  /// `modal`, `banner` or `fullscreen`; null for cards.
  final String? format;

  /// Banners: `top` or `bottom`. Modals: `bottom` (a sheet) or `center`.
  final String? position;

  /// Short line above the title; empty when there is none.
  final String eyebrow;
  final String title;
  final String body;
  final String? imageUrl;

  /// Modals and full screens with an image: `top` or `background`.
  final String? imagePlacement;
  final List<InAppButton> buttons;
  final Map<String, String> data;
  final InAppStyle style;
  final bool pinned;
  final String createdAt;
  final String? expiresAt;
  final String? displayedAt;
  final String? readAt;
  final String? dismissedAt;

  bool get isCard => kind == 'card';
  String get resolvedFormat => format ?? 'modal';
  String get resolvedPosition => position ?? 'bottom';
  bool get isRead => readAt != null;

  InAppMessage copyWith({String? readAt}) => InAppMessage(
        id: id,
        kind: kind,
        format: format,
        position: position,
        eyebrow: eyebrow,
        title: title,
        body: body,
        imageUrl: imageUrl,
        imagePlacement: imagePlacement,
        buttons: buttons,
        data: data,
        style: style,
        pinned: pinned,
        createdAt: createdAt,
        expiresAt: expiresAt,
        displayedAt: displayedAt,
        readAt: readAt ?? this.readAt,
        dismissedAt: dismissedAt,
      );

  /// Parses one feed item, or returns null when it is malformed.
  static InAppMessage? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final kind = json['kind'];
    if (id is! String || (kind != 'message' && kind != 'card')) return null;
    final data = <String, String>{};
    final rawData = json['data'];
    if (rawData is Map) {
      rawData.forEach((key, value) {
        if (value is String) data['$key'] = value;
      });
    }
    return InAppMessage(
      id: id,
      kind: kind as String,
      format: _string(json['format']),
      position: _string(json['position']),
      eyebrow: _string(json['eyebrow']) ?? '',
      title: _string(json['title']) ?? '',
      body: _string(json['body']) ?? '',
      imageUrl: _string(json['imageUrl']),
      imagePlacement: _string(json['imagePlacement']),
      buttons: (json['buttons'] is List)
          ? (json['buttons'] as List).map(InAppButton.fromJson).whereType<InAppButton>().toList()
          : const [],
      data: data,
      style: InAppStyle.fromJson(json['style']),
      pinned: json['pinned'] == true,
      createdAt: _string(json['createdAt']) ?? '',
      expiresAt: _string(json['expiresAt']),
      displayedAt: _string(json['displayedAt']),
      readAt: _string(json['readAt']),
      dismissedAt: _string(json['dismissedAt']),
    );
  }
}

class InAppButton {
  const InAppButton({required this.label, required this.action, this.url});

  final String label;

  /// `open_url` or `dismiss`.
  final String action;

  /// Null for dismiss buttons.
  final String? url;

  bool get opensUrl => action == 'open_url';

  static InAppButton? fromJson(Object? json) {
    if (json is! Map || json['label'] is! String) return null;
    final action = json['action'] == 'dismiss' ? 'dismiss' : 'open_url';
    return InAppButton(label: json['label'] as String, action: action, url: _string(json['url']));
  }

  @override
  bool operator ==(Object other) =>
      other is InAppButton && other.label == label && other.action == action && other.url == url;

  @override
  int get hashCode => Object.hash(label, action, url);
}

/// Resolved colors (`#rrggbb`), radii in logical pixels and the brand font stack.
class InAppStyle {
  const InAppStyle({
    required this.backgroundColor,
    required this.textColor,
    required this.mutedTextColor,
    required this.buttonColor,
    required this.buttonTextColor,
    required this.cornerRadius,
    required this.buttonRadius,
    required this.fontFamily,
  });

  static const fallback = InAppStyle(
    backgroundColor: '#ffffff',
    textColor: '#111827',
    mutedTextColor: '#4b5563',
    buttonColor: '#111827',
    buttonTextColor: '#ffffff',
    cornerRadius: 12,
    buttonRadius: 8,
    fontFamily: '',
  );

  final String backgroundColor;
  final String textColor;
  final String mutedTextColor;
  final String buttonColor;
  final String buttonTextColor;
  final double cornerRadius;
  final double buttonRadius;
  final String fontFamily;

  static const _generic = {'serif', 'sans-serif', 'monospace', 'system-ui', 'cursive'};

  /// Font families from the CSS stack, without quotes or generic names.
  List<String> get fontFamilies => fontFamily
      .split(',')
      .map((family) => family.trim().replaceAll(RegExp(r'''^["']|["']$'''), ''))
      .where((family) => family.isNotEmpty && !_generic.contains(family.toLowerCase()))
      .toList();

  static InAppStyle fromJson(Object? json) {
    if (json is! Map) return fallback;
    double number(Object? value, double otherwise) => value is num ? value.toDouble() : otherwise;
    return InAppStyle(
      backgroundColor: _string(json['backgroundColor']) ?? fallback.backgroundColor,
      textColor: _string(json['textColor']) ?? fallback.textColor,
      mutedTextColor: _string(json['mutedTextColor']) ?? fallback.mutedTextColor,
      buttonColor: _string(json['buttonColor']) ?? fallback.buttonColor,
      buttonTextColor: _string(json['buttonTextColor']) ?? fallback.buttonTextColor,
      cornerRadius: number(json['cornerRadius'], fallback.cornerRadius),
      buttonRadius: number(json['buttonRadius'], fallback.buttonRadius),
      fontFamily: _string(json['fontFamily']) ?? fallback.fontFamily,
    );
  }
}

/// `displayed`, `clicked`, `dismissed` or `read`.
enum InAppEventType { displayed, clicked, dismissed, read }

/// The fields Sequenzy adds to every push notification.
class PushPayload {
  const PushPayload({
    required this.title,
    required this.body,
    required this.url,
    required this.imageUrl,
    required this.pushSendId,
    required this.deviceId,
    required this.clickToken,
    required this.eventsUrl,
  });

  final String title;
  final String body;
  final String? url;
  final String? imageUrl;
  final String pushSendId;
  final String deviceId;
  final String clickToken;
  final String eventsUrl;

  /// Reads `RemoteMessage.data` from firebase_messaging, or an APNs userInfo
  /// map with a nested `sequenzy` key. Returns null for other senders.
  static PushPayload? fromData(Map<dynamic, dynamic>? data) {
    if (data == null) return null;
    final nested = data['sequenzy'];
    final source = nested is Map ? nested : data;
    String? read(String key) {
      final value = source[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num) return '$value';
      return null;
    }

    final pushSendId = read('pushSendId');
    final deviceId = read('deviceId');
    final clickToken = read('clickToken');
    final eventsUrl = read('eventsUrl');
    if (pushSendId == null || deviceId == null || clickToken == null || eventsUrl == null) return null;
    if (!eventsUrl.startsWith('https://') && !eventsUrl.startsWith('http://')) return null;
    return PushPayload(
      title: read('title') ?? '',
      body: read('body') ?? '',
      url: read('url'),
      imageUrl: read('imageUrl'),
      pushSendId: pushSendId,
      deviceId: deviceId,
      clickToken: clickToken,
      eventsUrl: eventsUrl,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PushPayload &&
      other.title == title &&
      other.body == body &&
      other.url == url &&
      other.imageUrl == imageUrl &&
      other.pushSendId == pushSendId &&
      other.deviceId == deviceId &&
      other.clickToken == clickToken &&
      other.eventsUrl == eventsUrl;

  @override
  int get hashCode => Object.hash(title, body, url, imageUrl, pushSendId, deviceId, clickToken, eventsUrl);
}

String? _string(Object? value) => value is String ? value : null;

/// A product, with the same fields as the web SDK's `viewedProduct`.
class CommerceProduct {
  const CommerceProduct({
    required this.providerProductId,
    this.providerVariantId,
    this.title,
    this.variantTitle,
    this.imageUrl,
    this.url,
    this.price,
    this.priceCents,
    this.currency,
    this.sku,
  });

  final String providerProductId;
  final String? providerVariantId;
  final String? title;
  final String? variantTitle;
  final String? imageUrl;
  final String? url;

  /// Major units, for example 19.99; or pass [priceCents].
  final num? price;
  final int? priceCents;
  final String? currency;
  final String? sku;

  Map<String, Object?> toJson() => {
        'providerProductId': providerProductId,
        if (providerVariantId != null) 'providerVariantId': providerVariantId,
        if (title != null) 'title': title,
        if (variantTitle != null) 'variantTitle': variantTitle,
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (url != null) 'url': url,
        if (price != null) 'price': price,
        if (priceCents != null) 'priceCents': priceCents,
        if (currency != null) 'currency': currency,
        if (sku != null) 'sku': sku,
      };
}

class CommerceCartLine {
  const CommerceCartLine({required this.product, required this.quantity, this.lineItemId});

  final CommerceProduct product;
  final int quantity;
  final String? lineItemId;

  Map<String, Object?> toJson() => {
        ...product.toJson(),
        'quantity': quantity,
        if (lineItemId != null) 'lineItemId': lineItemId,
      };
}

class CommerceCart {
  const CommerceCart({
    required this.lineItems,
    this.cartId,
    this.totalQuantity,
    this.totalPriceCents,
    this.currency,
  });

  final List<CommerceCartLine> lineItems;
  final String? cartId;
  final int? totalQuantity;
  final int? totalPriceCents;
  final String? currency;

  Map<String, Object?> toJson() => {
        if (cartId != null) 'cartId': cartId,
        'itemCount': lineItems.length,
        if (totalQuantity != null) 'totalQuantity': totalQuantity,
        if (totalPriceCents != null) 'totalPriceCents': totalPriceCents,
        if (currency != null) 'currency': currency,
        'lineItems': lineItems.map((line) => line.toJson()).toList(),
      };
}

class CommerceCollection {
  const CommerceCollection({required this.providerCollectionId, this.title, this.handle, this.url});

  final String providerCollectionId;
  final String? title;
  final String? handle;
  final String? url;

  Map<String, Object?> toJson() => {
        'providerCollectionId': providerCollectionId,
        if (title != null) 'title': title,
        if (handle != null) 'handle': handle,
        if (url != null) 'url': url,
      };
}

/// A change to the signed-in contact's profile. Omitted values stay as they
/// are; set [clearFirstName] or [clearLastName], or an attribute to null, to
/// clear one.
class ProfileUpdate {
  const ProfileUpdate({
    this.firstName,
    this.lastName,
    this.attributes,
    this.clearFirstName = false,
    this.clearLastName = false,
  });

  final String? firstName;
  final String? lastName;
  final Map<String, Object?>? attributes;
  final bool clearFirstName;
  final bool clearLastName;

  Map<String, Object?> toJson() => {
        if (firstName != null || clearFirstName) 'firstName': clearFirstName ? null : firstName,
        if (lastName != null || clearLastName) 'lastName': clearLastName ? null : lastName,
        if (attributes != null) 'attributes': attributes,
      };
}

/// A newsletter or waitlist signup through a published Sequenzy form.
class SubscribeRequest {
  const SubscribeRequest({
    required this.formId,
    required this.email,
    this.firstName,
    this.lastName,
    this.phone,
    this.attributes,
  });

  final String formId;
  final String email;
  final String? firstName;
  final String? lastName;

  /// For forms with a phone field; E.164 such as +14155550123.
  final String? phone;

  /// Values for the form's custom fields.
  final Map<String, Object?>? attributes;
}

class SubscribeResult {
  const SubscribeResult.success()
      : ok = true,
        error = null,
        retryable = false;
  const SubscribeResult.failure(String this.error, {required this.retryable}) : ok = false;

  final bool ok;
  final String? error;
  final bool retryable;
}
