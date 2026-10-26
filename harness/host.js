'use strict';
/**
 * host.js — mock of the app's SDPluginServer, for developing plugins without the
 * hardware and without running the vendor app.
 *
 * It reproduces what the reverse-engineered binary does:
 *   1. listens on 127.0.0.1:<ephemeral or fixed port>          (SDPluginServer::startListen)
 *   2. spawns a plugin with the Elgato-compatible argv contract (SDPluginManager)
 *   3. accepts { event: 'registerPlugin', uuid }  and binds socket->uuid
 *   4. emits willAppear / didReceiveSettings / keyDown / keyUp / dialRotate
 *   5. applies setTitle / setImage / setState and prints the resulting "device" state
 *
 * Usage:
 *   node harness/host.js examples/hello-plugin.js
 *   node harness/host.js examples/hello-plugin.js --port 9100 --interactive
 */
const path = require('path');
const { spawn } = require('child_process');
const { listen } = require('../sdk/wsproto');

const UUID = 'com.example.hello';
const ACTION = 'com.example.hello.action1';
const CONTEXT = 'ctx-A1B2C3';
const APPLICATION_INFO = {
  application: { language: 'en', platform: 'mac', version: '2.10.179.426' },
  plugin: { uuid: UUID, version: '1.0.0' },
  device: { id: 'MOCK-01', name: 'Stream Dock Mock', type: 'Keypad', size: { columns: 5, rows: 3 } },
};

function deviceState() {
  return { title: '', image: null, state: 0 };
}

async function main() {
  const pluginPath = process.argv[2];
  if (!pluginPath) {
    console.error('usage: node host.js <plugin.js> [--port N] [--interactive]');
    process.exit(2);
  }
  const portArg = process.argv.indexOf('--port');
  const port = portArg > 0 ? Number(process.argv[portArg + 1]) : 0;
  const interactive = process.argv.includes('--interactive');

  const server = await listen(port);
  const state = deviceState();
  const sockets = new Map(); // uuid -> ws

  console.log(`[host] SDPluginServer mock listening on 127.0.0.1:${server.port}`);

  server.on('connection', (ws) => {
    ws.on('message', (msg) => {
      if (msg.event === 'registerPlugin' || msg.event === 'registerPropertyInspector') {
        sockets.set(msg.uuid, ws);
        console.log(`[host] <- ${msg.event} uuid=${msg.uuid} from ${ws.remote}`);
        return;
      }
      if (msg.event === 'getSettings') {
        console.log(`[host] <- getSettings context=${msg.context}`);
        ws.send({ event: 'didReceiveSettings', action: ACTION, context: msg.context, payload: { city: 'Kuala Lumpur' } });
        return;
      }
      if (msg.event === 'getGlobalSettings') {
        ws.send({ event: 'didReceiveGlobalSettings', payload: { installId: 'mock-install' } });
        return;
      }
      if (msg.event === 'setTitle') {
        state.title = msg.payload.title;
        console.log(`[host] <- setTitle  ->  key shows "${state.title}"`);
        return;
      }
      if (msg.event === 'setImage') {
        state.image = String(msg.payload.image).slice(0, 42);
        console.log(`[host] <- setImage  ->  bitmap ${state.image}...`);
        return;
      }
      if (msg.event === 'setState') {
        state.state = msg.payload.state;
        console.log(`[host] <- setState  ->  state ${state.state}`);
        return;
      }
      if (msg.event === 'setSettings' || msg.event === 'setGlobalSettings') {
        console.log(`[host] <- ${msg.event} ${JSON.stringify(msg.payload).slice(0, 120)}`);
        return;
      }
      if (msg.event === 'showOk' || msg.event === 'showAlert') {
        console.log(`[host] <- ${msg.event} (key feedback)`);
        return;
      }
      if (msg.event === 'openUrl') {
        console.log(`[host] <- openUrl ${msg.payload.url}   [host would /usr/bin/open this]`);
        return;
      }
      if (msg.event === 'logMessage') {
        console.log(`[host] <- logMessage ${msg.payload.message}`);
        return;
      }
      console.log(`[host] <- ${msg.event} ${JSON.stringify(msg).slice(0, 160)}`);
    });
    ws.on('close', () => console.log('[host] socket closed'));
  });

  // Spawn exactly the way SDPluginManager does: -port -pluginUUID -registerEvent -info
  const argv = ['-port', String(server.port), '-pluginUUID', UUID,
    '-registerEvent', 'registerPlugin', '-info', JSON.stringify(APPLICATION_INFO)];
  console.log(`[host] spawn ${path.basename(pluginPath)} ${argv[0]} ${argv[1]} -pluginUUID ${UUID} ...`);
  const child = spawn(process.execPath, [pluginPath, ...argv], { stdio: ['ignore', 'inherit', 'inherit'] });
  child.on('exit', (code) => {
    console.log(`[host] plugin exited (${code})`);
    server.close();
    process.exit(0);
  });

  const send = (payload) => {
    for (const ws of sockets.values()) ws.send(payload);
  };

  const waitForPlugin = async () => {
    for (let i = 0; i < 50; i++) {
      if (sockets.size) return;
      await new Promise((r) => setTimeout(r, 100));
    }
    throw new Error('plugin never registered');
  };
  await waitForPlugin();

  const session = {
    willAppear: () => send({ event: 'willAppear', action: ACTION, context: CONTEXT, device: 'MOCK-01', payload: { settings: { city: 'Kuala Lumpur' }, coordinates: { column: 0, row: 0 } } }),
    keyDown: () => send({ event: 'keyDown', action: ACTION, context: CONTEXT, device: 'MOCK-01', payload: { settings: { city: 'Kuala Lumpur' }, coordinates: { column: 0, row: 0 } } }),
    keyUp: () => send({ event: 'keyUp', action: ACTION, context: CONTEXT, device: 'MOCK-01', payload: { settings: { city: 'Kuala Lumpur' }, coordinates: { column: 0, row: 0 } } }),
    dialRotate: (ticks = 1) => send({ event: 'dialRotate', action: ACTION, context: CONTEXT, device: 'MOCK-01', payload: { ticks, pressed: false } }),
    willDisappear: () => send({ event: 'willDisappear', action: ACTION, context: CONTEXT, device: 'MOCK-01', payload: {} }),
  };

  console.log('[host] -> willAppear');
  session.willAppear();
  await new Promise((r) => setTimeout(r, 300));

  if (interactive) {
    console.log('[host] interactive: k=keyDown, u=keyUp, r=dialRotate, q=quit');
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (buf) => {
      for (const c of buf.trim()) {
        if (c === 'k') session.keyDown();
        else if (c === 'u') session.keyUp();
        else if (c === 'r') session.dialRotate(1);
        else if (c === 'q') { child.kill(); }
      }
    });
    return;
  }

  console.log('[host] -> keyDown');
  session.keyDown();
  await new Promise((r) => setTimeout(r, 400));
  console.log('[host] -> keyUp');
  session.keyUp();
  await new Promise((r) => setTimeout(r, 400));
  console.log(`[host] final key state: ${JSON.stringify(state)}`);
  child.kill();
}

main().catch((e) => {
  console.error('[host] fatal:', e.message);
  process.exit(1);
});
