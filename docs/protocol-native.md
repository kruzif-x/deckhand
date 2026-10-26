# Stream Dock 293S — HID protocol

Everything below was recovered from `libtransport.dylib` (arm64 slice, Ghidra) and then implemented
from scratch in `Sources/Deckhand/NativeTransport.swift`. No vendor code is shipped or required.

## Transport

* Device: VID `0x5548`, PID `0x6674`, usage page `0xFFA0`
* Interface: 512-byte input and output reports; the vendor SDK calls this a report size of **513**
  (1 report-ID byte + 512 payload)
* Every message is one or more output reports: `[reportID][payload…][0x00 padding to 512]`
* `reportID` is `0x00` on this firmware. `IOHIDDeviceSetReport(kIOHIDReportTypeOutput, reportID,
  payload, 512)`
* An image is **two kinds of report**: first a 13-byte header report, then the JPEG itself in
  **512-byte chunks** (`TransportSession::chunkSize` = 513). Sending header and JPEG as one stream,
  or using 511-byte chunks, produces a garbled picture — verified on hardware.
* The panel does not acknowledge image reports; the vendor's own read times out. Pace the writes
  (~2 ms) instead of waiting

## Commands

All ASCII-tagged; multi-byte integers are big-endian.

| Purpose | Bytes | Recovered from |
|---|---|---|
| Set key/window image | `"CRT\0\0BAT"` + `BE32(jpegLength)` + `key` + JPEG bytes | `Transport::setKeyImgFileStream` |
| Brightness | `"CRT\0\0LIG"` + `0x00 0x00` + `percent` | `Transport::setKeyBrightness` |
| Heartbeat | `"CRT\0\0CONNECT"` (12 bytes) | `Transport::heartbeat` |
| Change page | `"M_V"` + `page` | `Transport::changePage` |

`key` is the **hardware** key code, not the visual position:

```
logical  1  2  3  4  5 |  6  7  8  9 10 | 11 12 13 14 15 | 16 17 18
hardware13 10  7  4  1 | 14 11  8  5  2 | 15 12  9  6  3 | 16 17 18
```

## Input

* 512-byte input report, `byte[9]` = hardware key code, `byte[10]` = state (always `0x00`)
* One report per press, **no release event**; the firmware repeats the report while a key is held,
  so the host debounces (350 ms is what Deckhand uses)
* Keys 16–18 (the 1×3 window) never produce input — display only

## Pages

The panel stores no page data: `"M_V" + page` was accepted for 0, 1, 2, 3, 8, 15, 31 and 255 with no
error and no NAK, and the firmware does not remember which page it was told. Paging is entirely
host-side — the app re-pushes the images for the page it wants to show. The 4-page cap is a product
decision, not a hardware limit.

## Firmware string

Not exposed by the transport. Read it with `IOHIDDeviceGetReport(kIOHIDReportTypeFeature, id, …)` for
`id` 1…8 and take the first reply starting with `V` (this unit answers `V2.293.00.001`).
