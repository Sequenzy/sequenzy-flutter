## 0.1.2

- Fixes and improvements.

## Unreleased

- Custom HTML in-app messages: `SequenzyInAppHost` shows `html` messages
  (surveys, Braze-style custom HTML) in a WebView with the Sequenzy JS bridge;
  `showHtmlMessages: false` turns them off. Adds a `webview_flutter`
  dependency. `fetchMessages(includeHtml: true)`, `report(..., buttonId:)`.
  `InAppMessage.format` can now be `html`.

## 0.1.1

- iOS Live Activities: `Sequenzy.registerLiveActivityToken` and
  `Sequenzy.liveActivityEnded` pass ActivityKit tokens from your native code,
  so your backend can start, update and end activities through Sequenzy.
- README: links to Sequenzy, the guides and the other SDKs.

## 0.1.0

- First release: identify contacts, track events, screens and commerce events,
  register push tokens and show in-app messages and content cards.
