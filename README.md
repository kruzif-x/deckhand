# Stream Dock (AJAZZ 2.10.179.426) — reverse-engineered interface + redesign

Two deliverables from one static analysis pass over
`Stream-Dock-AJAZZ-Installer_Mac_global2.0.pkg`:

    1. the plugin/machine interface, reconstructed and made runnable
       (protocol spec + zero-dependency SDK + mock host, tested on the app's own Node)
    2. the user interface, reviewed against the vendor's real assets and redesigned
       (interactive prototype + before/after screenshots)

Nothing here modifies or redistributes vendor code; every file is written from scratch
against behaviour observed in the shipped artifacts.

## Layout

    device/                        the actual unit, measured and driven
      hidprobe.swift               read-only IOHIDManager probe (properties, feature GET)
      probe-output.txt             captured output (firmware string V2.293.00.001)
      drive_test.py                draws key faces through the vendor's open SDK, no app
      sdk/                         vendored StreamDock Python SDK (MIT) + PID patch note
      listen-log.txt               input events captured while listening
      README.md                    what the device exposes and what it does not
    docs/plugin-protocol.md        reconstructed protocol: transport, launch contract,
                                   handshake, every event, unknown stays unknown
    docs/ui-review.md              interface critique with evidence, and what changed
    sdk/wsproto.js                 RFC6455 client+server, zero dependencies
    sdk/sd.js                      minimal plugin SDK (Session.fromArgv(), setTitle, ...)
    harness/host.js                mock of the app's SDPluginServer: spawns a plugin with
                                   the exact argv contract and drives keyDown/keyUp
    examples/hello-plugin.js       reference plugin, runs in the harness or the real app
    qt/                            the working prototype: a real Qt Quick app
      main.py                      launcher / single-frame capture
      qml/Main.qml                 the whole UI, vector-drawn, no assets
      selftest.py                  drives the app and asserts behaviour
      run.sh                       ./run.sh | --test | --capture out.png
    ui/action-editor.html          the browser mockup (kept for comparison)
    ui/preview-qt.png              Qt app, default state (2880x1800 @2x)
    ui/preview-qt-state2.png       Qt app, second state: °F, custom title "Office"
    ui/preview.png                 browser mockup at 1440x900
    ui/before-vendor-pi.png        the vendor's weather panel, same content

## Run the harness

Use the same runtime the app ships (no npm install, no internet):

    NODE="/Users/rolandchia/.hermes/profiles/redteam/cache/scratch/streamdock/expanded/Payload/Stream Dock AJAZZ.app/Contents/Helpers/node20"
    "$NODE" harness/host.js examples/hello-plugin.js
    "$NODE" harness/host.js examples/hello-plugin.js --interactive     # k/u/r/q

Reference output (v20.11.1):

    [host] SDPluginServer mock listening on 127.0.0.1:49988
    [host] <- registerPlugin uuid=com.example.hello from 127.0.0.1:49989
    [plugin] registered as com.example.hello on port 49988 (registerPlugin), lang=en
    [host] -> willAppear
    [host] <- getSettings context=ctx-A1B2C3
    [host] <- setTitle  ->  key shows "Hello Kuala"
    [host] -> keyDown
    [host] <- setState  ->  state 1
    [host] <- showOk (key feedback)
    [host] <- setTitle  ->  key shows "Pressed 10:34:59"
    [host] final key state: {"title":"Pressed 10:34:59","image":"imgs/hello@2x.png","state":0}

That round trip exercises: argv contract, WS upgrade, register handshake, getSettings
request/reply, setTitle/setImage/setState/showOk, and clean shutdown — i.e. the parts of
the protocol a plugin actually needs.

## Write a plugin against it

```js
const { Session } = require('./sdk/sd');
const s = Session.fromArgv();                 // works in the real app too
s.on('keyDown', m => s.setTitle(m.context, 'hi'));
s.start();
```
Manifest shape is the vendor's (`UUID`, `Actions[]`, `CodePath`, `OS[]`, `SDKVersion`,
optional `Nodejs: {Version:"20"}`) — see any bundled `.sdPlugin`.

## The hardware, as measured

`device/hidprobe` opens the unit through IOHIDManager and reads only — no output reports,
no writes:

    VID/PID 0x5548/0x6674, USB bcdDevice 0x0300, full speed, no serial, no product string
    HID descriptor: vendor pages 0xFFA0/0xFFA1 only, 512-byte in + 512-byte out
    feature report GET -> "V2.293.00.001"   (same for every report id)
    unsolicited input reports in 6 s: 0

So: no keyboard/mouse/consumer usages (it cannot type), no unsolicited traffic (it cannot
push anything on its own), and the firmware string — which the USB descriptors do not
carry — identifies it as a Stream Dock 293-series unit. Neither vendor firmware manifest
contains this PID, so the app has no update to offer it. Full write-up in
`device/README.md`.

## Run the Qt prototype

A real application, not a mockup: Qt Quick (PySide6 6.12 / Qt 6.12), all vector-drawn,
no image assets, 1440x900 window. `run.sh` installs **PySide6-Essentials** (~375 MB venv)
rather than the full PySide6 meta-package (~1.3 GB) — Essentials already ships QtQuick and
QtQuickControls2, and the prototype was rendered and self-tested on both.

    cd qt
    ./run.sh                 # launch it
    ./run.sh --test          # behaviour self-test, prints PASS/FAIL
    ./run.sh --capture out.png

Self-test output — these are read back out of the live QML object graph, so a pass means
the bindings actually work, not that the pixels look right:

    initial state
      PASS  selected action: 0
      PASS  weather panel shown: True
      PASS  preview temp: '31°'
    selecting a different key
      PASS  action name: False            (switches to the generic action panel)
      PASS  multi-action panel: False
      PASS  back to weather: True
    unit switch drives the preview
      PASS  preview temp after °F: '88°'
    show-city switch reveals the custom title
      PASS  preview city from custom title: 'Office'
      PASS  preview city back to city: 'Kuala Lumpur'
    typing a city updates the preview
      PASS  preview city: 'George Town'
    save-state machine
      PASS  settles to saved: 'saved'     (state right after edit: 'dirty')
    0 failure(s)

What it demonstrates beyond the mockup: real Qt text metrics and layout, real focus
handling on Qt TextInput, a working save-state machine (dirty -> saving -> saved), a
two-panel inspector that actually swaps between a configured action and one with no
settings, and a selected key that renders the *same* state as the inspector preview
because both bind to one source of truth.

## The redesign in one paragraph

Same three-pane model the app already implies (pages/scenes rail, device canvas, action
inspector), with the defects fixed: the selected key and the live preview now show the
same thing at device size; 2-option radio rows become visible segmented controls; the
show/hide pair becomes a switch with an inline state and a dependent field that actually
hides; controls share one 104 px label column, 32 px height and a 4/8/12/16/24 spacing
scale; every section is grouped and labelled; destructive actions get a saved-state
indicator and a single primary action instead of another modal; and the inspector gains
the trust surface the product currently lacks — publisher, signature state and the
capabilities the plugin asks for, plus an honest status bar (HTTP store, outdated CEF and
Node). Contrast was raised to ≥4.5:1 on secondary text and every control has a visible
focus ring.

## Honest limits

* Static analysis only. The protocol is reconstructed from the vendor's own client code
  and the app's symbol table; the harness validates internal consistency, not vendor
  behaviour. Payload schemas for the vendor-only extensions (`setRGB`, `setBackground`,
  `sendToDevice`, `showAcTop`) are named but not fully resolved.
* The UI prototype is HTML/CSS/JS, not Qt. It demonstrates the design, not a patch to the
  vendor's C++.
* No attempt was made to bypass code signing, alter the installed app, or interact with
  vendor servers beyond read-only GETs to public URLs.
