# Stream Dock plugin protocol — reconstructed specification

Everything here is derived from artifacts inside `Stream-Dock-AJAZZ-Installer_Mac_global2.0.pkg`
(app 2.10.179.426). Each claim is tagged with where it came from:

  [OBS] observed in shipped client code (JS the app loads)
  [SYM] recovered from the app's own symbol table (`nm -C`, class `SDPluginServer`)
  [STR] literal string in the binary or the store bundle
  [INF] inference from the above, not proven — flagged explicitly

Verified end to end with the harness in `../harness/host.js` +
`../examples/hello-plugin.js` running on the app's own runtime
(`Contents/Helpers/node20`, v20.11.1).

---

## 1. Transport

    ws://127.0.0.1:<port>/            [OBS] `new WebSocket('ws://127.0.0.1:' + inPort)`
    RFC 6455, text frames, JSON body  [OBS] `websocket.sendJSON(json)` / `Utils.parseJson(evt.data)`
    server binds loopback             [STR] `http://127.0.0.1:%1/`, `127.0.0.1`
    port is ephemeral, chosen by the app at start [SYM] `SDPluginServer::startListen(unsigned short)`
                                                    `SDPluginServer::getServerPort()`

Two independent sockets are involved:

    SDPluginServer   plugin <-> app            (this document)
    SDStore          store web view <-> app    (different envelope, see §8)

## 2. Launch contract (Node plugins)

The app spawns a plugin process and passes the socket coordinates on argv. The layout
is visible in the bundled emoji plugin: [OBS]

    new WebSocket("ws://127.0.0.1:" + process.argv[3])
    ws.on("open", () => ws.send(JSON.stringify({ uuid: process.argv[5], event: process.argv[7] })))
    ... JSON.parse(process.argv[9]).application.language

which resolves to the Elgato-compatible form:

    <node> <plugin.js> -port <port> -pluginUUID <uuid> -registerEvent registerPlugin -info <applicationInfo JSON>

      argv[2]  "-port"            argv[3]  port
      argv[4]  "-pluginUUID"      argv[5]  plugin UUID (matches manifest "UUID"/"PUUID")
      argv[6]  "-registerEvent"   argv[7]  "registerPlugin"
      argv[8]  "-info"            argv[9]  applicationInfo JSON

`applicationInfo` observed shape: [INF from usage]

    { "application": { "language": "en", "platform": "mac", "version": "2.10.179.426" },
      "plugin":      { "uuid": "...", "version": "1.0.0" },
      "device":      { "id": "...", "name": "...", "type": "Keypad", "size": {"columns":5,"rows":3} } }

## 3. Registration handshake

    plugin  -> host   { "event": "registerPlugin",             "uuid": "<plugin uuid>" }
    PI      -> host   { "event": "registerPropertyInspector",  "uuid": "<pi uuid>" }

No authentication token, no nonce, no Origin check. [OBS] handshake, [SYM]
`SDPluginServer::handleNewConnection` takes `nextPendingConnection()` and wires signals;
neither the app nor `libSDLibrary` imports `QWebSocketCorsAuthenticator`, and there is no
`Origin`/`Referer` string in the binary — i.e. the Qt origin-check hook is not used. [INF]
A local process (or a page in any browser) can likely register as any UUID it knows.

The PI is handed its coordinates by the CEF host page through a JS function: [OBS]

    connectElgatoStreamDeckSocket(port, uuid, messageType, applicationInfoJson, actionInfoJson)

and the store front-end uses a second, unrelated helper: `<script>function connectSocket(n){window.$port=n}</script>`. [OBS]

## 4. Message envelope

    { "event": "<name>", "action": "<action uuid>", "context": "<per-instance id>",
      "device": "<device id>", "payload": { ... } }                        [OBS]

* `context` identifies one key/dial instance; it is created by the host and must be
  echoed back on every per-instance command.
* The client SDK demultiplexes with `action + '.' + event` for plugin sockets and always
  with `sendToPropertyInspector` for PI sockets. [OBS]

## 5. Host -> plugin events

| event | payload (observed / inferred) | notes |
|---|---|---|
| `willAppear` | `settings`, `coordinates{column,row}`, `state`, `isInMultiAction` | sent when a key becomes visible |
| `willDisappear` | `settings`, `coordinates`, `state` | |
| `keyDown` / `keyUp` | `settings`, `coordinates`, `state`, `userDesiredState` | host also has `keyDownCord`/`keyUpCord` variants carrying pointer coordinates [SYM] |
| `dialDown` / `dialUp` / `dialRotate` | `settings`, `coordinates`, `ticks`, `pressed`, `controller` | knob devices |
| `touchTap` | `settings`, `coordinates`, `tapPos`, `hold` | touch-bar devices [STR] |
| `titleParametersDidChange` | `title`, `titleParameters{fontFamily,fontSize,fontStyle,titleColor,titleAlignment,showTitle}`, `coordinates`, `state` | |
| `didReceiveSettings` | `{...}` — reply to `getSettings` | |
| `didReceiveGlobalSettings` | `{...}` — reply to `getGlobalSettings` | |
| `propertyInspectorDidAppear` / `DidDisappear` | `action`, `context`, `device` | |
| `sendToPlugin` | arbitrary `payload` from the PI | PI -> plugin relay |
| `deviceDidConnect` / `deviceDidDisconnect` | `device`, `deviceInfo{name,size,type}` | [SYM] |
| `applicationDidLaunch` / `applicationDidTerminate` | `payload.application` | used by scene/profile switches [SYM] |
| `systemDidWakeUp` | empty | [SYM] |
| `lockScreen` / `unLockScreen` | — | vendor extension [SYM] |

## 6. Plugin -> host events

Elgato-compatible core (all seen in shipped plugin code): [OBS]

    setTitle      { title, target, state }            key title
    setImage      { image, target, state }            base64 data URL or relative path
    setState      { state }                           multi-state actions
    setSettings   { ... }                             persist per-instance settings
    getSettings   {}                                  -> didReceiveSettings
    setGlobalSettings / getGlobalSettings            plugin-wide storage
    sendToPropertyInspector { payload }              to the PI
    sendToPlugin  { payload }                        from the PI
    showOk / showAlert                               key feedback
    openUrl       { url }                            host runs /usr/bin/open
    logMessage    { message }                        written to the app log
    switchToProfile { device, profile }

Stream Dock extensions beyond the Elgato surface, enumerated from the server's own
signal names: [SYM]

    setRGB { ... }                     per-key LED control
    setBackground / stopBackground     animated backgrounds on the key
    sendToDevice { ... }               raw device command channel (also binary frames:
                                       `SDPluginServer::onBinaryMessageReceived`)
    showAcTop { ... }                  on-screen activity toast
    switchFolderProfile / switchFromFolderProfile
    touchbar* (enter/exit folder, form folder)
    registerWebRequiredCommand         capability handshake for web-hosted plugins
    connectDevice / webConnectDevice   device association for the web runtime

## 7. Unresolved / unknown

These stay open on purpose rather than being guessed:

* exact schema of `setRGB`, `setBackground`, `sendToDevice`, `showAcTop` payloads —
  only their names and the fact that a payload object is passed are recovered
* whether `registerWebRequiredCommand` gates any capability check
* whether the host validates that a `registerPlugin` UUID was actually spawned by it
  (no evidence either way in the accept path)
* multi-device routing: `device` field is present in the envelope, but the routing rules
  for a plugin serving several devices are not observable statically

## 8. The second interface: store web view

Separate socket, separate envelope: [OBS]

    new WebSocket(`ws://127.0.0.1:${window.$port}`)
    send({ streamdockStoreModule: "index", streamdockStoreEvent: "registerIndex" })
    send({ streamdockStoreModule: "index", streamdockStoreEvent: "showStreamDock" })
    send({ streamdockStoreEvent: "openUrl", payload: { url } })

Catalog calls are plain HTTP (see the security review, finding F1):

    http://47.106.243.57:8088/getDiscoverLinkbyLang?language=en
    http://47.106.243.57:8088/getManualLinkbyLang?language=en
    http://47.106.243.57:8088/getPlugByCount      (needs ?state=)
    http://47.106.243.57:8088/incDownloadsById

## 9. What a better contract would look like

The wire format is fine (it is the de-facto industry one). What is missing is
authority: nothing in the protocol says what a plugin is allowed to do, and nothing
authenticates a client.

    + per-session token   host generates a 128-bit nonce per plugin process, passes it in
                          argv (`-sessionToken`), requires it in the register message and
                          rejects any other connection; PI gets its own token scoped to
                          one action context.
    + origin check        reject WS upgrades whose Origin is not file:// (CEF pages) or
                          absent (native plugins); this is one call to
                          QWebSocketServer::setOriginAuthenticationRequired + a validator.
    + declared caps       manifest gains "Capabilities": ["device.led", "net",
                          "fs.read:<dir>", "process.spawn"] and the host enforces them
                          server-side (refuse setRGB if not granted) instead of trusting
                          `PrivateAPI: true`.
    + schema versioning   `"SDKVersion": 2` plus a typed envelope with a `v` field, so new
                          events can be added without breaking old plugins.
    + size limits         cap JSON frame and binary frame size (the binary channel is
                          currently unbounded) and rate-limit per context.

None of that changes the developer experience — it is all host-side plus one extra
argv entry and one manifest key.
