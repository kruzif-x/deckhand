## Deckhand 0.1b (beta)

A native macOS driver and UI for the AJAZZ Stream Dock 293S (also sold as AKP153). 2.4 MB of Swift
instead of the vendor's ~1.4 GB Electron app, talking to the panel over IOKit with no vendor binary
loaded or shipped.

**Download:** `Deckhand-0.1b.dmg` — signed with Developer ID and notarised by Apple
(`source=Notarized Developer ID`), so it opens without a Gatekeeper warning. Drag Deckhand to
Applications.

### What works (each of these verified on the hardware)

- all 18 slots: 15 keys and the 1×3 display window, with per-key graphics and window widgets
  (clock, date, CPU, memory, page number, text)
- physical key presses, 15 keys, 350 ms debounce
- bindings: key combination, open app, open URL, run script, mute / volume up / volume down,
  page next / previous / first
- profiles with up to 4 host-side pages, save/save-as to `.sdprofile`, duplicate and remove
- image library: 78 built-in graphics plus anything you import
- hot-plug: unplug shows "Not connected", replug reconnects
- menu-bar mode: closing the window keeps the panel working; ⌘? opens the help book
- MCP server (`deckhand-mcp`) with 13 tools, switchable off in Settings

### Known limits

- **macOS 14+, Apple silicon only** (arm64 build)
- pages are host-side: the firmware stores none, and 4 pages is a product cap, not a hardware limit
- if the panel ever stops responding to writes — even to its own vendor app — unplug the USB-C cable for
  a couple of seconds and replug; Deckhand reconnects on its own. This is a firmware behaviour, not
  something the app can recover from in place
- built-in graphics live in the app bundle, imported ones in
  `~/Library/Application Support/Deckhand/Library` — they are per-Mac, not part of a profile

### Verify the download

```
shasum -a 256 Deckhand-0.1b.dmg
b022d9597caf2be8a93550f488854a753be6bdecde0542a2221e13a2f636026b
```

### How this was built

The HID protocol was recovered by static analysis of the vendor library (Ghidra), then confirmed by
capturing its reports with lldb — the image command is a 13-byte `CRT\0\0BAT` header report followed by
the JPEG in 512-byte reports, with `STP` to commit and `DIS` to wake. Notes:
`docs/protocol-native.md`. No vendor code is linked, copied or redistributed.

MIT licensed.
