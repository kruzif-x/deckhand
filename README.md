# Deckhand

A native macOS driver and UI for the AJAZZ Stream Dock 293S (VID `0x5548`, PID `0x6674`).

The vendor application is ~1.4 GB of Electron/CEF. Deckhand is 2.4 MB of Swift that talks to the panel
over IOKit, with no vendor binary loaded, shipped or required — the HID protocol was recovered by static
analysis of the vendor library and then verified against the hardware, byte for byte.

    app/          the macOS app (SwiftPM) + MCP server     → app/README.md
    docs/         recovered protocol, plugin protocol, UI review
    device/       bring-up tooling used to probe the unit (Python/Swift, no vendor code)
    re/           analysis harnesses: vendor A/B reference driver, lldb report-capture script
    sdk/ harness/ examples/   a separate, smaller result: the vendor's plugin protocol,
                              reconstructed (RFC6455 client/server, mock host, sample plugin)

## What it does

* 15 keys + a 1×3 display window, 4 host-side pages per profile
* per-key graphics with an optional crop/rotate/zoom step, or use the file untouched
* bindings: key combination, open app, open URL, run script, page next / previous / first
* window panes render clock, date, CPU, memory, page number or custom text
* profiles saved as `.sdprofile`, **Save / Save As**, storage folders configurable in Settings
* follows the system language (English, 简体中文, Bahasa Melayu)
* MCP server so an agent can drive it through the app's control socket

## Status — verified on the hardware

| area | state |
|---|---|
| display: 18 slots, images and window widgets | verified |
| physical presses, 15 keys, 350 ms debounce | verified |
| bindings (two keys launched two different apps) | verified |
| hot-plug unplug → "Not connected" → replug reconnect | verified |
| clearing a key, then Send to Device blanks it | verified |
| pages and page-navigation actions | verified |
| brightness · wake · commit · heartbeat | implemented from the decompile |

## How the protocol was recovered

The vendor library (`libtransport.dylib`) is a few hundred KB that statically links hidapi and adds a
thin `transport_*` layer. Only the payload framing was actually unknown, so the work was:

1. `otool`/`nm` to see it links IOKit and exports all of hidapi — the USB plumbing was never the secret
   part.
2. Ghidra on the thinned arm64 slice for `Transport::setKeyImgFileStream`, `setKeyBrightness`,
   `heartbeat`, `changePage`, `wakeupScreen` and `TransportSession::transact`.
3. An lldb breakpoint on `IOHIDDeviceSetReport` in a harness that calls the vendor API, to capture the
   literal report bytes and confirm the decompiled reading.

Result (`docs/protocol-native.md`): an image is **two transmissions** — a 13-byte `CRT\0\0BAT` header
report, then the JPEG in **512-byte** reports — with `STP` to commit, `DIS` to wake, `CONNECT` as
keep-alive, and `M_V` + page to switch. The panel does not acknowledge writes; the vendor's own read
times out. Each of those three details was a bug that looked like "writes succeed, nothing appears", and
each is documented so it isn't rediscovered.

## Build

    cd app && ./build.sh
    open Deckhand.app

macOS 14+, Xcode command line tools, arm64. While Deckhand runs it owns the HID device; other tools
should use its control socket (`~/Library/Application Support/Deckhand/control.sock`) or the MCP server.

## Licence

MIT (`LICENSE`). No vendor code is included: the vendored SDK used as a reference oracle during
development has been deleted from the tree, and the driver is a fresh implementation of the observed
protocol. The vendor binary itself was never redistributed.
