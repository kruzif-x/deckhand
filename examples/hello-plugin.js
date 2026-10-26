'use strict';
/**
 * hello-plugin.js — reference plugin written against the reconstructed protocol.
 * Runs unmodified in the vendor app (same argv contract) or under the mock host.
 */
const { Session } = require('../sdk/sd');

const session = Session.fromArgv();
let settings = {};

session.on('open', ({ port, uuid, event }) => {
  console.log(`[plugin] registered as ${uuid} on port ${port} (${event}), lang=${session.language}`);
});

session.on('willAppear', async (msg) => {
  const ctx = msg.context;
  settings = await session.getSettings(ctx);
  const city = settings.city || 'nowhere';
  session.setTitle(ctx, `Hello ${city.split(' ')[0]}`);
  session.setImage(ctx, 'imgs/hello@2x.png');
  console.log(`[plugin] willAppear -> title "Hello ${city.split(' ')[0]}"`);
});

session.on('keyDown', (msg) => {
  session.setState(msg.context, 1);
  session.showOk(msg.context);
  session.setTitle(msg.context, `Pressed ${new Date().toISOString().slice(11, 19)}`);
  session.logMessage('hello-plugin handled keyDown');
  console.log('[plugin] keyDown -> setState(1), showOk, new title');
});

session.on('keyUp', (msg) => {
  session.setState(msg.context, 0);
  console.log('[plugin] keyUp -> setState(0)');
});

session.on('dialRotate', (msg) => {
  session.setTitle(msg.context, `ticks ${msg.payload.ticks}`);
});

session.on('close', () => process.exit(0));

session.start().catch((e) => {
  console.error('[plugin] connect failed:', e.message);
  process.exit(1);
});
