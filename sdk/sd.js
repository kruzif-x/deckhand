'use strict';
/**
 * sd.js — minimal client for the Stream Dock plugin protocol, reconstructed from
 * the vendor's own shipped client code (see docs/plugin-protocol.md for the evidence
 * trail: static/action.js, plugin/index.js of the bundled sdPlugins, and the
 * SDPluginServer signal list in the app binary).
 *
 * Launch contract reproduced from the app (Elgato-compatible):
 *   node <plugin.js> -port <p> -pluginUUID <uuid> -registerEvent registerPlugin -info <json>
 * so process.argv is:
 *   [0]=node [1]=script [2]=-port [3]=port [4]=-pluginUUID [5]=uuid
 *   [6]=-registerEvent [7]=registerPlugin [8]=-info [9]=applicationInfo JSON
 *
 * `Session.fromArgv()` accepts exactly that layout. Nothing here is guessed: the
 * argv indices come from the bundled emoji plugin's bootstrap
 * (`new WebSocket("ws://127.0.0.1:" + process.argv[3])`,
 *  `send({uuid: process.argv[5], event: process.argv[7]})`,
 *  `process.argv[9]).application.language`).
 */
const { connect } = require('./wsproto');
const { EventEmitter } = require('events');

const PLUGIN = 'registerPlugin';
const PROPERTY_INSPECTOR = 'registerPropertyInspector';

class Session extends EventEmitter {
  /**
   * @param {object} opts
   * @param {number} opts.port          host port (SDPluginServer::getServerPort)
   * @param {string} opts.uuid          plugin UUID or PI UUID
   * @param {string} [opts.event]       'registerPlugin' | 'registerPropertyInspector'
   * @param {object} [opts.applicationInfo]
   */
  constructor(opts) {
    super();
    this.port = opts.port;
    this.uuid = opts.uuid;
    this.event = opts.event || PLUGIN;
    this.applicationInfo = opts.applicationInfo || {};
    this.actionInfo = null;
    this.ws = null;
    this._context = null;
    this._pending = new Map();
  }

  static fromArgv(argv = process.argv) {
    const arg = (flag) => {
      const i = argv.indexOf(flag);
      return i > 0 && i + 1 < argv.length ? argv[i + 1] : undefined;
    };
    const info = arg('-info');
    let applicationInfo = {};
    try { applicationInfo = info ? JSON.parse(info) : {}; } catch { /* keep {} */ }
    return new Session({
      port: Number(arg('-port')),
      uuid: arg('-pluginUUID'),
      event: arg('-registerEvent') || PLUGIN,
      applicationInfo,
    });
  }

  get language() {
    return (this.applicationInfo.application || {}).language || 'en';
  }

  async start() {
    this.ws = await connect(this.port);
    this.ws.on('message', (msg) => this._dispatch(msg));
    this.ws.on('close', () => this.emit('close'));
    this.ws.send({ event: this.event, uuid: this.uuid });
    this.emit('open', { port: this.port, uuid: this.uuid, event: this.event });
    return this;
  }

  _dispatch(msg) {
    if (msg.event === 'didReceiveSettings' && msg.context) {
      const waiter = this._pending.get(`settings:${msg.context}`);
      if (waiter) { this._pending.delete(`settings:${msg.context}`); waiter(msg.payload); }
    }
    if (msg.event === 'didReceiveGlobalSettings') {
      const waiter = this._pending.get('settings:global');
      if (waiter) { this._pending.delete('settings:global'); waiter(msg.payload); }
    }
    if (msg.context) this._context = msg.context;
    this.emit('event', msg);
    this.emit(msg.event, msg);
    // SDK convenience channels, mirroring the vendor's `action.uuid + '.' + event` keying
    if (msg.action) this.emit(`${msg.action}.${msg.event}`, msg);
  }

  // ---- outbound -----------------------------------------------------------
  setTitle(context, title, target = 0, state = 0) {
    this.ws.send({ event: 'setTitle', context, payload: { title, target, state } });
  }
  setImage(context, image, target = 0, state = 0) {
    this.ws.send({ event: 'setImage', context, payload: { image, target, state } });
  }
  setState(context, state) {
    this.ws.send({ event: 'setState', context, payload: { state } });
  }
  setSettings(context, payload) {
    this.ws.send({ event: 'setSettings', context, payload });
  }
  setGlobalSettings(context, payload) {
    this.ws.send({ event: 'setGlobalSettings', context, payload });
  }
  /** Returns a promise resolved by the host's didReceiveSettings reply. */
  getSettings(context) {
    return this._request(`settings:${context}`, { event: 'getSettings', context });
  }
  getGlobalSettings(context) {
    return this._request('settings:global', { event: 'getGlobalSettings', context });
  }
  sendToPropertyInspector(action, context, payload) {
    this.ws.send({ event: 'sendToPropertyInspector', action, context, payload });
  }
  sendToPlugin(action, context, payload) {
    this.ws.send({ event: 'sendToPlugin', action, context, payload });
  }
  showAlert(context) { this.ws.send({ event: 'showAlert', context }); }
  showOk(context) { this.ws.send({ event: 'showOk', context }); }
  openUrl(url) { this.ws.send({ event: 'openUrl', payload: { url } }); }
  /** Stream Dock extension over the Elgato base: raw device/LED commands. */
  setRGB(context, payload) { this.ws.send({ event: 'setRGB', context, payload }); }
  sendToDevice(context, payload) { this.ws.send({ event: 'sendToDevice', context, payload }); }
  switchToProfile(context, device, profile) {
    this.ws.send({ event: 'switchToProfile', context, device, payload: { profile } });
  }
  logMessage(message) { this.ws.send({ event: 'logMessage', payload: { message } }); }

  _request(key, msg, timeoutMs = 2000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this._pending.delete(key);
        reject(new Error(`timeout waiting for ${msg.event} reply`));
      }, timeoutMs);
      this._pending.set(key, (payload) => { clearTimeout(timer); resolve(payload); });
      this.ws.send(msg);
    });
  }

  close() { if (this.ws) this.ws.close(); }
}

module.exports = { Session, PLUGIN, PROPERTY_INSPECTOR };
