# Interface review + redesign

Two "interfaces" were reverse engineered: the one users see, and the one plugins talk to
(`plugin-protocol.md`). This file covers the first, using the app's own assets as evidence.

    ui/before-vendor-pi.png   the vendor's weather property inspector, rendered from the
                              shipped file at the width the app allocates (~420 px)
    qt/                       the working prototype — a real Qt Quick app (PySide6 6.12)
    ui/preview-qt.png         the Qt app, default state
    ui/preview-qt-state2.png  the Qt app after toggling show-city off, °F, custom title
    ui/action-editor.html     browser mockup, kept for comparison
    ui/preview.png            the browser mockup at 1440x900

The Qt prototype is the deliverable; the HTML file was the fast iteration pass. Both
implement the same design, the Qt build adds real text metrics, real focus handling and a
behaviour self-test (`cd qt && ./run.sh --test`).

## 1. What the current UI is built from (evidence)

* 752 user-facing strings, 14 languages, embedded as JSON blobs in the main binary
  (`en` blob at 0x36d3ee4, ~479 strings; the merged table is 752 keys).
* Global palette recovered from the shipped QSS:
  `rgb(45,45,45)` base, `rgb(60/71,60/71,60/71)` surfaces, `rgb(122,122,122)` borders,
  accent `#2980b9`, text `rgb(230,230,230)`; 218 style blocks in total.
* Window/panel classes: `SDToolbarWidget`, `SDActionCanvasWidget`, `SDPropertyInspectorWidget`,
  `SDProfileEditor`, `SDIconLibrary`, `SDBackgroundLibraryM3`, `SDMultiActionListWidget`,
  `SDDeviceDisplayWidget`, `SDPages`, `SDStore`, `SDNotificationWidget`.
* Plugin config panels are separate HTML pages (`propertyInspector/…/index.html`) loaded in
  CEF with the vendor's `sdpi.css` design language — they are NOT covered by the app's i18n.

## 2. Defects visible in the vendor's own config panel

Rendered at 420x620 (`before-vendor-pi.png`):

1. Content is a ~280 px column pinned to the top-left; the remaining ~65% of the panel is
   empty. No card, no sections, no grouping.
2. No visible selected state on any radio group — three 2-option radio rows all read as
   unselected, so you cannot tell the current provider, whether the city name shows, or
   which title mode is active.
3. Control widths disagree (the search dropdown is ~half the width of the other selects,
   and its "Update" button pushes that row past the common right edge).
4. Labels are left-aligned into a fixed 64 px column; gaps to controls are ragged, and
   all editing affordances sit ~30 px apart with 22 px control heights — below the 44 px
   macOS hit target.
5. No preview of what the key will look like, no save/persistence feedback, no empty or
   error state for the dropdown, no hover/focus styling.
6. It is hardcoded Chinese while the host app has 14 locales: a global user gets a Chinese
   panel. That is a product decision made by omission, not a translation gap.

Panel-level issues in the rest of the app, from its own strings:

7. Destructive actions are confirmed by modal dialog — 9 separate `Sure*` strings
   (`SureDeleteOperation`, `SureUninstallPlugin`, `SureUninstallIconLibrary`,
   `SureDeleteFile`, `SureDownFile`, `SureCancelDownload`, `SureInstallPlugin`,
   `SureInstallIconLibrary`, `SureRelpaceOperation`) — instead of undo.
   `ResetDataToolTips` = "The current operation will clear all data and restart the
   program!" is a one-shot, irreversible action with no preview of what is lost.
8. English copy is Title Case Every Word and mixes full-width CJK punctuation into English
   strings: **55 of the 752 strings** contain `！`, `？`, `，` or `。` — e.g.
   `"WebSocket Server Address Cannot Be Empty！"`,
   `"Drag An Action From The Right，Place It On The Empty Button Above。"`,
   `"Are You Sure You Want To Delete This Action？"`,
   `"Accessibility Is Required To Properly Use Hotkey Functionality。"`.
9. Typos are user-visible because keys are hand-written — 10 of them in user-facing copy:
   `DeviceNotConenect`, `FaildToConnectOBS`, `SetPowerOnFaildToolTips`, `DwonloadError`,
   `DwonloadingNewVersion`, `OpenPluginDwonloadDir`, `FirmwareFileDotNoExists`,
   `PasteFaild`, `ReCordVedio`, `CapShotScreen`.
10. Onboarding is a five-slide overlay (`TopTopHelp_Title_1..5`) plus a separate
    `_noSpace` variant, plus `ConnectHelpTips0..11` — 16 strings of help for the two
    primary actions (drag an action, switch a scene).
11. No trust surface anywhere: plugins are installed from an HTTP catalogue (see the
    security review) and the UI never shows publisher, signature or requested permissions.

## 3. The redesign

Structure: left rail (pages + scenes) / device canvas / inspector — the same three-pane
model the app already implies via `SDPages` + `SDActionCanvasWidget` +
`SDPropertyInspectorWidget`, but with the hierarchy fixed.

Concrete changes, each mapped to a defect above:

| # | change | fixes |
|---|---|---|
| 1 | Selected key and inspector preview show the same content and aspect ratio (104x104 square, 31° / Kuala Lumpur) | D2, D5 |
| 2 | Grouped inspector sections (Preview / Location / Display / Permissions) with uppercase section headers and dividers | D1, D4 |
| 3 | Segmented controls replace 2-option radio rows; selected segment is filled with the accent | D2 |
| 4 | Switch with inline On/Off state replaces the show/hide radio pair; the dependent "Custom title" field is hidden (`.field[hidden]`) until it applies | D2, D5 |
| 5 | Uniform 32 px control height, single 104 px label column, right-aligned labels, 4/8/12/16/24 spacing scale | D3, D4 |
| 6 | Live key preview rendered at device size, updating as fields change | D5 |
| 7 | "This plugin can" permission chips (network host list, file scope, screen capture) + "Review publisher & signature" | D11 |
| 8 | Persistent "All changes saved" indicator in the inspector footer; Reset is a ghost button, Done is the single primary action | D7 |
| 9 | Status bar states the truth the app currently hides: `Plugin store: HTTP — not trusted`, `CEF 109 · node 20.11.1 (outdated)` | D11 |
| 10 | Warnings carry a glyph + tooltip, not just colour; attention badge is `!` on amber, explained once in the legend next to the grid | accessibility |
| 11 | Contrast raised: `--text-faint` #9a9a9a on #242424 (≈5.1:1), section headers #a3a3a3, focus ring 3 px accent halo, `:focus-visible` everywhere | D4 |
| 12 | Number-key-free empty slots: centred `+` in a dashed tile — a clear drop target, not a broken key | D1 |

Keyboard and state coverage in the prototype: `⌘K` focuses search, every control is a real
form element (tab order works), switches/segments expose `aria-pressed`/`checked`, the
canvas uses `aria-pressed` for selection, and empty/preview/live states are present.

## 4. What still has to be decided by the vendor

* **Plugin panel ownership.** The inspector you see in the prototype can only exist if the
  host renders the settings UI (schema-driven forms) or if plugin PIs adopt a shared
  component kit. Today every plugin ships its own HTML with its own typography — that is
  why the vendor's own weather PI looks nothing like the host app.
* **Undo instead of 28 confirmations.** Delete/uninstall/reset need a single undo stack
  (⌘Z) plus an explicit "Reset data" danger zone, not modals everywhere.
* **Localisation contract for plugin UI.** Either force PIs through the host's i18n
  catalog (`sendToPropertyInspector` already has a channel for it) or require PIs to ship
  their own locale files keyed by the host language.
* **Trust surface.** Publisher, signature, requested capabilities and the transport used
  for installation belong in the UI, because the user cannot otherwise make the choice
  the security review asks them to make.
